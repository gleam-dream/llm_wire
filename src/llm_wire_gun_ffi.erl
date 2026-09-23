-module(llm_wire_gun_ffi).
-export([connect_and_stream/15, connect_and_stream_with_pool/16, connect_and_stream_gleam/16, send_request_more/1, send_close/1, handle_pid/1, now_ms/0]).

-record(state, {
    parent,
    owner,
    owner_monitor,
    pool,
    lease_ref,
    conn,
    conn_mon,
    stream_ref,
    on_chunk,
    on_eof,
    on_error,
    deadline,
    max_chunk_bytes
}).

connect_and_stream(Host, Port, Path, Headers, Body, OverallTimeout, TlsMode, CaFile,
        MaxHeaderBytes, MaxChunkBytes, OwnerPid, OnChunk, OnEof, OnError,
        OnRequestSent) ->
    connect_and_stream_with_pool(undefined, Host, Port, Path, Headers, Body,
        OverallTimeout, TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes,
        OwnerPid, OnChunk, OnEof, OnError, OnRequestSent).

connect_and_stream_gleam(PoolOption, Host, Port, Path, Headers, Body, OverallTimeout,
        TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes, OwnerPid, OnChunk,
        OnEof, OnError, OnRequestSent) ->
    Pool = case PoolOption of
        {some, P} -> P;
        none -> undefined;
        P when is_pid(P) -> P;
        _ -> undefined
    end,
    connect_and_stream_with_pool(Pool, Host, Port, Path, Headers, Body,
        OverallTimeout, TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes,
        OwnerPid, OnChunk, OnEof, OnError, OnRequestSent).

connect_and_stream_with_pool(Pool, Host, Port, Path, Headers, Body, OverallTimeout,
        TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes, OwnerPid, OnChunk,
        OnEof, OnError, OnRequestSent) ->
    Parent = self(),
    Ref = make_ref(),
    Deadline = now_ms() + OverallTimeout,
    {Pid, BridgeMonitor} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        OwnerMonitor = erlang:monitor(process, OwnerPid),
        init_bridge(Parent, Ref, OwnerPid, OwnerMonitor, Pool, Host, Port, Path,
            Headers, Body, Deadline, TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes,
            OnChunk, OnEof, OnError, OnRequestSent)
    end),
    receive
        {Ref, ok} ->
            erlang:demonitor(BridgeMonitor, [flush]),
            {ok, Pid};
        {Ref, {error, Error}} ->
            erlang:demonitor(BridgeMonitor, [flush]),
            {error, Error};
        {'DOWN', BridgeMonitor, process, Pid, Reason} ->
            {error, {gun_failure, {transport_failure, format_error(Reason)}}}
    after remaining_ms(Deadline) + 50 ->
        erlang:demonitor(BridgeMonitor, [flush]),
        exit(Pid, kill),
        {error, {gun_failure, overall_deadline_failure}}
    end.

init_bridge(Parent, Ref, Owner, OwnerMonitor, Pool, Host, Port, Path, Headers, Body,
        Deadline, TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes, OnChunk, OnEof,
        OnError, OnRequestSent) ->
    _ = application:ensure_all_started(gun),
    case Pool of
        undefined ->
            init_standalone(Parent, Ref, Owner, OwnerMonitor, Host, Port, Path,
                Headers, Body, Deadline, TlsMode, CaFile, MaxHeaderBytes,
                MaxChunkBytes, OnChunk, OnEof, OnError, OnRequestSent);
        _ ->
            init_pooled(Parent, Ref, Owner, OwnerMonitor, Pool, Host, Port, Path,
                Headers, Body, Deadline, TlsMode, CaFile, MaxHeaderBytes,
                MaxChunkBytes, OnChunk, OnEof, OnError, OnRequestSent)
    end.

init_standalone(Parent, Ref, Owner, OwnerMonitor, Host, Port, Path, Headers, Body,
        Deadline, TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes, OnChunk, OnEof,
        OnError, OnRequestSent) ->
    Transport = case TlsMode of <<"plaintext">> -> tcp; _ -> tls end,
    TlsOpts = case TlsMode of
        <<"plaintext">> -> [];
        <<"verify_system">> ->
            [{verify, verify_peer},
             {cacerts, public_key:cacerts_get()},
             {server_name_indication, binary_to_list(Host)},
             {customize_hostname_check,
                [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}];
        <<"verify_ca_file">> ->
            [{verify, verify_peer},
             {cacertfile, binary_to_list(CaFile)},
             {server_name_indication, binary_to_list(Host)},
             {customize_hostname_check,
                [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]
    end,
    GunOpts = #{
        transport => Transport,
        protocols => [http],
        retry => 0,
        tls_opts => TlsOpts,
        http_opts => #{
            max_headers => 100,
            max_header_block_size => MaxHeaderBytes,
            max_trailer_block_size => MaxHeaderBytes
        }
    },
    case gun:open(binary_to_list(Host), Port, GunOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, remaining_ms(Deadline)) of
                {ok, _Protocol} ->
                    ConnMon = erlang:monitor(process, Conn),
                    GunHeaders = [{K, V} || {K, V} <- Headers],
                    StreamRef = gun:post(Conn, Path, GunHeaders, Body, #{flow => 1}),
                    OnRequestSent(),
                    wait_for_response(Parent, Ref, Owner, OwnerMonitor, undefined, undefined,
                        Conn, ConnMon, StreamRef, Deadline, MaxHeaderBytes, MaxChunkBytes,
                        OnChunk, OnEof, OnError);
                {error, Reason} ->
                    gun:close(Conn),
                    Failure = case Reason of
                        timeout -> overall_deadline_failure;
                        _ -> {transport_failure, format_error(Reason)}
                    end,
                    Parent ! {Ref, {error, {gun_failure, Failure}}}
            end;
        {error, Reason} ->
            Parent ! {Ref, {error, {gun_failure, {transport_failure, format_error(Reason)}}}}
    end.

init_pooled(Parent, Ref, Owner, OwnerMonitor, Pool, Host, Port, Path, Headers, Body,
        Deadline, TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes, OnChunk, OnEof,
        OnError, OnRequestSent) ->
    Target = {Host, Port, TlsMode, CaFile},
    CheckoutTimeout = remaining_ms(Deadline),
    case llm_wire_gun_pool:checkout(Pool, Target, CheckoutTimeout, self()) of
        {ok, Conn, LeaseRef} ->
            ConnMon = erlang:monitor(process, Conn),
            GunHeaders = [{K, V} || {K, V} <- Headers],
            StreamRef = gun:post(Conn, Path, GunHeaders, Body, #{flow => 1, reply_to => self()}),
            OnRequestSent(),
            wait_for_response(Parent, Ref, Owner, OwnerMonitor, Pool, LeaseRef,
                Conn, ConnMon, StreamRef, Deadline, MaxHeaderBytes, MaxChunkBytes,
                OnChunk, OnEof, OnError);
        {error, pool_timeout} ->
            Parent ! {Ref, {error, {gun_failure, overall_deadline_failure}}};
        {error, Reason} ->
            Parent ! {Ref, {error, {gun_failure, {transport_failure, format_error(Reason)}}}}
    end.

wait_for_response(Parent, Ref, Owner, OwnerMonitor, Pool, LeaseRef, Conn, ConnMon,
        StreamRef, Deadline, MaxHeaderBytes, MaxChunkBytes, OnChunk, OnEof, OnError) ->
    receive
        {gun_response, Conn, StreamRef, Fin, Status, Headers} ->
            case header_block_bytes(Headers) > MaxHeaderBytes of
                true ->
                    gun:cancel(Conn, StreamRef),
                    cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
                    Parent ! {Ref, {error, {gun_failure, {transport_failure, <<"response header block limit exceeded">>}}}};
                false -> handle_response_headers(Parent, Ref, Owner,
                    OwnerMonitor, Pool, LeaseRef, Conn, ConnMon, StreamRef, Fin, Status, Headers,
                    Deadline, MaxChunkBytes, OnChunk, OnEof, OnError)
            end;
        {gun_error, Conn, StreamRef, Reason} ->
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
            Parent ! {Ref, {error, {gun_failure, {transport_failure, format_error(Reason)}}}};
        {gun_error, Conn, Reason} ->
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
            Parent ! {Ref, {error, {gun_failure, {transport_failure, format_error(Reason)}}}};
        {'DOWN', ConnMon, process, Conn, Reason} ->
            cleanup_conn(Pool, LeaseRef, Conn, undefined, closed),
            Parent ! {Ref, {error, {gun_failure, {transport_failure, format_error(Reason)}}}};
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            gun:cancel(Conn, StreamRef),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
            Parent ! {Ref, {error, {gun_failure, {transport_failure, <<"stream owner stopped during setup">>}}}};
        {'EXIT', Parent, _Reason} ->
            gun:cancel(Conn, StreamRef),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed)
    after remaining_ms(Deadline) ->
        gun:cancel(Conn, StreamRef),
        cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
        Parent ! {Ref, {error, {gun_failure, overall_deadline_failure}}}
    end.

handle_response_headers(Parent, Ref, Owner, OwnerMonitor, Pool, LeaseRef, Conn, ConnMon,
        StreamRef, Fin, Status, Headers, Deadline, MaxChunkBytes, OnChunk, OnEof, OnError) ->
    case {Status, supported_response_headers(Headers)} of
        {200, ok} ->
            Parent ! {Ref, ok},
            case Fin of
                fin ->
                    OnEof(),
                    cleanup_conn(Pool, LeaseRef, Conn, ConnMon, ok);
                nofin ->
                    loop(#state{parent=Parent, owner=Owner,
                        owner_monitor=OwnerMonitor, pool=Pool,
                        lease_ref=LeaseRef, conn=Conn, conn_mon=ConnMon,
                        stream_ref=StreamRef, on_chunk=OnChunk,
                        on_eof=OnEof, on_error=OnError,
                        deadline=Deadline,
                        max_chunk_bytes=MaxChunkBytes})
            end;
        {200, {error, Reason}} ->
            gun:cancel(Conn, StreamRef),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
            Parent ! {Ref, {error, {gun_failure, {transport_failure, Reason}}}};
        {OtherStatus, _} ->
            read_error_body(Parent, Ref, Owner, OwnerMonitor, Pool, LeaseRef,
                Conn, ConnMon, StreamRef, OtherStatus, retry_after_value(Headers),
                Fin, Deadline, <<>>)
    end.

header_block_bytes(Headers) ->
    lists:sum([iolist_size(Name) + iolist_size(Value) + 4
        || {Name, Value} <- Headers]).

retry_after_value(Headers) ->
    case header_value(<<"retry-after">>, Headers) of
        undefined -> <<>>;
        Value -> Value
    end.

supported_response_headers(Headers) ->
    ContentType = header_value(<<"content-type">>, Headers),
    Encoding = header_value(<<"content-encoding">>, Headers),
    case {is_event_stream(ContentType), Encoding} of
        {true, undefined} -> ok;
        {true, <<"identity">>} -> ok;
        {false, _} -> {error, <<"response is not text/event-stream">>};
        {true, _} -> {error, <<"compressed responses are not accepted">>}
    end.

header_value(_Name, []) -> undefined;
header_value(Name, [{Name, Value} | _]) ->
    iolist_to_binary(Value);
header_value(Name, [_ | Rest]) -> header_value(Name, Rest).

is_event_stream(undefined) -> false;
is_event_stream(Value) when is_binary(Value) ->
    case binary:split(Value, <<";">>) of
        [MediaType | _] -> string_lower(MediaType) =:= <<"text/event-stream">>;
        _ -> false
    end.

string_lower(Value) -> list_to_binary(string:lowercase(binary_to_list(Value))).

read_error_body(Parent, Ref, Owner, OwnerMonitor, Pool, LeaseRef, Conn, ConnMon,
        StreamRef, Status, RetryAfter, Fin, Deadline, Acc) ->
    case Fin of
        fin ->
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
            Parent ! {Ref, {error, {gun_status, Status, Acc, RetryAfter}}};
        nofin ->
            gun:update_flow(Conn, StreamRef, 1),
            receive
                {gun_data, Conn, StreamRef, DataFin, Data} ->
                    NextSize = byte_size(Acc) + byte_size(Data),
                    case NextSize > 65536 of
                        true ->
                            gun:cancel(Conn, StreamRef),
                            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
                            Parent ! {Ref, {error, {gun_failure, {transport_failure, <<"error response body limit exceeded">>}}}};
                        false ->
                            read_error_body(Parent, Ref, Owner, OwnerMonitor,
                                Pool, LeaseRef, Conn, ConnMon, StreamRef, Status,
                                RetryAfter, DataFin, Deadline, <<Acc/binary, Data/binary>>)
                    end;
                {gun_error, Conn, StreamRef, Reason} ->
                    cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
                    Parent ! {Ref, {error, {gun_failure, {transport_failure, format_error(Reason)}}}};
                {'DOWN', ConnMon, process, Conn, Reason} ->
                    cleanup_conn(Pool, LeaseRef, Conn, undefined, closed),
                    Parent ! {Ref, {error, {gun_failure, {transport_failure, format_error(Reason)}}}};
                {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
                    gun:cancel(Conn, StreamRef),
                    cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
                    Parent ! {Ref, {error, {gun_failure, {transport_failure, <<"stream owner stopped during setup">>}}}}
            after remaining_ms(Deadline) ->
                gun:cancel(Conn, StreamRef),
                cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
                Parent ! {Ref, {error, {gun_failure, overall_deadline_failure}}}
            end
    end.

loop(#state{parent=Parent, owner=Owner, owner_monitor=OwnerMonitor,
        pool=Pool, lease_ref=LeaseRef, conn=Conn, conn_mon=ConnMon,
        stream_ref=StreamRef, on_chunk=OnChunk, on_eof=OnEof,
        on_error=OnError, deadline=Deadline,
        max_chunk_bytes=MaxChunkBytes} = State) ->
    receive
        request_more ->
            gun:update_flow(Conn, StreamRef, 1),
            loop(State);
        close ->
            gun:cancel(Conn, StreamRef),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
            ok;
        {gun_data, Conn, StreamRef, nofin, Data} ->
            case byte_size(Data) > MaxChunkBytes of
                true ->
                    OnError({transport_failure, <<"response chunk byte limit exceeded">>}),
                    gun:cancel(Conn, StreamRef),
                    cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed);
                false ->
                    OnChunk(Data),
                    loop(State)
            end;
        {gun_data, Conn, StreamRef, fin, Data} ->
            case byte_size(Data) > MaxChunkBytes of
                true ->
                    OnError({transport_failure, <<"response chunk byte limit exceeded">>}),
                    cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed);
                false ->
                    OnChunk(Data),
                    OnEof(),
                    cleanup_conn(Pool, LeaseRef, Conn, ConnMon, ok)
            end;
        {gun_trailers, Conn, StreamRef, _Trailers} ->
            OnEof(),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, ok);
        {gun_error, Conn, StreamRef, Reason} ->
            OnError({transport_failure, format_error(Reason)}),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed);
        {gun_error, Conn, Reason} ->
            OnError({transport_failure, format_error(Reason)}),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed);
        {gun_down, Conn, _Proto, Reason, _Killed} ->
            OnError({transport_failure, format_error(Reason)}),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed);
        {'DOWN', ConnMon, process, Conn, Reason} ->
            OnError({transport_failure, format_error(Reason)}),
            cleanup_conn(Pool, LeaseRef, Conn, undefined, closed);
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            gun:cancel(Conn, StreamRef),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
            ok;
        {'EXIT', Parent, _Reason} ->
            gun:cancel(Conn, StreamRef),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed),
            ok;
        {overall_deadline, StreamRef} ->
            OnError(overall_deadline_failure),
            gun:cancel(Conn, StreamRef),
            cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed);
        _Other -> loop(State)
    after remaining_ms(Deadline) ->
        OnError(overall_deadline_failure),
        gun:cancel(Conn, StreamRef),
        cleanup_conn(Pool, LeaseRef, Conn, ConnMon, closed)
    end.

cleanup_conn(undefined, _LeaseRef, Conn, ConnMon, _Health) ->
    demonitor_safe(ConnMon),
    catch gun:close(Conn),
    ok;
cleanup_conn(Pool, LeaseRef, Conn, ConnMon, Health) ->
    demonitor_safe(ConnMon),
    case Health of
        ok -> llm_wire_gun_pool:checkin(Pool, LeaseRef, ok);
        _ ->
            catch gun:close(Conn),
            llm_wire_gun_pool:checkin(Pool, LeaseRef, Health)
    end,
    ok.

demonitor_safe(undefined) -> ok;
demonitor_safe(Mon) when is_reference(Mon) ->
    erlang:demonitor(Mon, [flush]),
    ok.

format_error(Reason) when is_binary(Reason) -> Reason;
format_error(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format_error(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

now_ms() -> erlang:monotonic_time(millisecond).

remaining_ms(Deadline) -> erlang:max(Deadline - now_ms(), 0).

send_request_more(Pid) ->
    Pid ! request_more,
    nil.

send_close(Pid) ->
    Pid ! close,
    nil.

handle_pid(Pid) -> Pid.
