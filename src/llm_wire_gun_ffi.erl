-module(llm_wire_gun_ffi).
-export([connect_and_stream/15, send_request_more/1, send_close/1, handle_pid/1, now_ms/0]).

-record(state, {
    parent,
    owner,
    owner_monitor,
    conn,
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
    Parent = self(),
    Ref = make_ref(),
    Deadline = now_ms() + OverallTimeout,
    {Pid, BridgeMonitor} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        OwnerMonitor = erlang:monitor(process, OwnerPid),
        init_bridge(Parent, Ref, OwnerPid, OwnerMonitor, Host, Port, Path,
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
            {error, {gun_failure, format_error(Reason)}}
    after remaining_ms(Deadline) + 50 ->
        erlang:demonitor(BridgeMonitor, [flush]),
        exit(Pid, kill),
        {error, {gun_failure, <<"overall deadline exceeded during setup">>}}
    end.

init_bridge(Parent, Ref, Owner, OwnerMonitor, Host, Port, Path, Headers, Body,
        Deadline, TlsMode, CaFile, MaxHeaderBytes, MaxChunkBytes, OnChunk, OnEof,
        OnError, OnRequestSent) ->
    _ = application:ensure_all_started(gun),
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
                    GunHeaders = [{K, V} || {K, V} <- Headers],
                    StreamRef = gun:post(Conn, Path, GunHeaders, Body, #{flow => 1}),
                    OnRequestSent(),
                    wait_for_response(Parent, Ref, Owner, OwnerMonitor, Conn,
                        StreamRef, Deadline, MaxHeaderBytes, MaxChunkBytes,
                        OnChunk, OnEof, OnError);
                {error, Reason} ->
                    gun:close(Conn),
                    Parent ! {Ref, {error, {gun_failure, format_error(Reason)}}}
            end;
        {error, Reason} ->
            Parent ! {Ref, {error, {gun_failure, format_error(Reason)}}}
    end.

wait_for_response(Parent, Ref, Owner, OwnerMonitor, Conn, StreamRef, Deadline,
        MaxHeaderBytes, MaxChunkBytes, OnChunk, OnEof, OnError) ->
    receive
        {gun_response, Conn, StreamRef, Fin, Status, Headers} ->
            case header_block_bytes(Headers) > MaxHeaderBytes of
                true ->
                    gun:cancel(Conn, StreamRef),
                    gun:close(Conn),
                    Parent ! {Ref, {error, {gun_failure, <<"response header block limit exceeded">>}}};
                false -> handle_response_headers(Parent, Ref, Owner,
                    OwnerMonitor, Conn, StreamRef, Fin, Status, Headers,
                    Deadline, MaxChunkBytes, OnChunk, OnEof, OnError)
            end;
        {gun_error, Conn, StreamRef, Reason} ->
            gun:close(Conn),
            Parent ! {Ref, {error, {gun_failure, format_error(Reason)}}};
        {gun_error, Conn, Reason} ->
            gun:close(Conn),
            Parent ! {Ref, {error, {gun_failure, format_error(Reason)}}};
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            gun:cancel(Conn, StreamRef),
            gun:close(Conn),
            Parent ! {Ref, {error, {gun_failure, <<"stream owner stopped during setup">>}}};
        {'EXIT', Parent, _Reason} ->
            gun:cancel(Conn, StreamRef),
            gun:close(Conn)
    after remaining_ms(Deadline) ->
        gun:cancel(Conn, StreamRef),
        gun:close(Conn),
        Parent ! {Ref, {error, {gun_failure, <<"overall deadline exceeded waiting for headers">>}}}
    end.

handle_response_headers(Parent, Ref, Owner, OwnerMonitor, Conn, StreamRef,
        Fin, Status, Headers, Deadline, MaxChunkBytes, OnChunk, OnEof, OnError) ->
            case {Status, supported_response_headers(Headers)} of
                {200, ok} ->
                    Parent ! {Ref, ok},
                    case Fin of
                        fin -> OnEof(), gun:close(Conn);
                        nofin ->
                            loop(#state{parent=Parent, owner=Owner,
                                owner_monitor=OwnerMonitor, conn=Conn,
                                stream_ref=StreamRef, on_chunk=OnChunk,
                                on_eof=OnEof, on_error=OnError,
                                deadline=Deadline,
                                max_chunk_bytes=MaxChunkBytes})
                    end;
                {200, {error, Reason}} ->
                    gun:cancel(Conn, StreamRef),
                    gun:close(Conn),
                    Parent ! {Ref, {error, {gun_failure, Reason}}};
                {OtherStatus, _} ->
                    read_error_body(Parent, Ref, Owner, OwnerMonitor, Conn,
                        StreamRef, OtherStatus, retry_after_value(Headers),
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

read_error_body(Parent, Ref, Owner, OwnerMonitor, Conn, StreamRef, Status,
        RetryAfter, Fin, Deadline, Acc) ->
    case Fin of
        fin ->
            gun:close(Conn),
            Parent ! {Ref, {error, {gun_status, Status, Acc, RetryAfter}}};
        nofin ->
            gun:update_flow(Conn, StreamRef, 1),
            receive
                {gun_data, Conn, StreamRef, DataFin, Data} ->
                    NextSize = byte_size(Acc) + byte_size(Data),
                    case NextSize > 65536 of
                        true ->
                            gun:cancel(Conn, StreamRef),
                            gun:close(Conn),
                            Parent ! {Ref, {error, {gun_failure, <<"error response body limit exceeded">>}}};
                        false ->
                            read_error_body(Parent, Ref, Owner, OwnerMonitor,
                                Conn, StreamRef, Status, RetryAfter, DataFin,
                                Deadline, <<Acc/binary, Data/binary>>)
                    end;
                {gun_error, Conn, StreamRef, Reason} ->
                    gun:close(Conn),
                    Parent ! {Ref, {error, {gun_failure, format_error(Reason)}}};
                {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
                    gun:cancel(Conn, StreamRef),
                    gun:close(Conn),
                    Parent ! {Ref, {error, {gun_failure, <<"stream owner stopped during setup">>}}}
            after remaining_ms(Deadline) ->
                gun:cancel(Conn, StreamRef),
                gun:close(Conn),
                Parent ! {Ref, {error, {gun_failure, <<"overall deadline exceeded reading error response">>}}}
            end
    end.

loop(#state{parent=Parent, owner=Owner, owner_monitor=OwnerMonitor,
        conn=Conn, stream_ref=StreamRef, on_chunk=OnChunk, on_eof=OnEof,
        on_error=OnError, deadline=Deadline,
        max_chunk_bytes=MaxChunkBytes} = State) ->
    receive
        request_more ->
            gun:update_flow(Conn, StreamRef, 1),
            loop(State);
        close ->
            gun:cancel(Conn, StreamRef),
            gun:close(Conn),
            ok;
        {gun_data, Conn, StreamRef, nofin, Data} ->
            case byte_size(Data) > MaxChunkBytes of
                true ->
                    OnError(<<"response chunk byte limit exceeded">>),
                    gun:cancel(Conn, StreamRef),
                    gun:close(Conn);
                false ->
                    OnChunk(Data),
                    loop(State)
            end;
        {gun_data, Conn, StreamRef, fin, Data} ->
            case byte_size(Data) > MaxChunkBytes of
                true -> OnError(<<"response chunk byte limit exceeded">>);
                false -> OnChunk(Data)
            end,
            OnEof(),
            gun:close(Conn);
        {gun_trailers, Conn, StreamRef, _Trailers} ->
            OnEof(),
            gun:close(Conn);
        {gun_error, Conn, StreamRef, Reason} ->
            OnError(format_error(Reason)),
            gun:close(Conn);
        {gun_error, Conn, Reason} ->
            OnError(format_error(Reason)),
            gun:close(Conn);
        {gun_down, Conn, _Proto, Reason, _Killed} ->
            OnError(format_error(Reason)),
            gun:close(Conn);
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            gun:cancel(Conn, StreamRef),
            gun:close(Conn),
            ok;
        {'EXIT', Parent, _Reason} ->
            gun:cancel(Conn, StreamRef),
            gun:close(Conn),
            ok;
        {overall_deadline, StreamRef} ->
            OnError(<<"overall deadline exceeded">>),
            gun:cancel(Conn, StreamRef),
            gun:close(Conn);
        _Other -> loop(State)
    after remaining_ms(Deadline) ->
        OnError(<<"overall deadline exceeded">>),
        gun:cancel(Conn, StreamRef),
        gun:close(Conn)
    end.

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
