-module(llm_wire_gun_pool).
-behaviour(gen_server).

-export([start_link/1, start/3, stop/1, checkout/4, checkin/3, pool_info/1, pool_info_tuple/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(target, {
    host,
    port,
    tls_mode,
    ca_file
}).

-record(conn_entry, {
    conn,
    gun_mon,
    owner_pid,
    target,
    state,        %% idle | {leased, LeaseRef, ClientPid, ClientMon}
    idle_since,
    created_at
}).

-record(waiter, {
    from,
    target,
    client_pid,
    client_mon,
    deadline,
    timer_ref
}).

-record(connecting, {
    ref,
    target,
    from,
    client_pid,
    client_mon,
    deadline,
    worker_pid,
    worker_mon,
    timer_ref
}).

-record(state, {
    max_per_target = 4,
    max_total = 16,
    idle_timeout_ms = 30000,
    conns = [],
    connecting = [],
    waiters = [],
    prune_timer
}).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

start(MaxPer, MaxTot, IdleMs) ->
    Opts = #{
        max_connections_per_target => MaxPer,
        max_total_connections => MaxTot,
        idle_timeout_ms => IdleMs
    },
    case gen_server:start(?MODULE, Opts, []) of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, format_error(Reason)}
    end.

stop(Pool) ->
    try
        case gen_server:stop(Pool, normal, 5000) of
            ok -> {ok, nil};
            Other -> {error, format_error(Other)}
        end
    catch
        exit:{timeout, _} -> {error, <<"pool_stop_timeout">>};
        exit:{noproc, _} -> {error, <<"pool_stopped">>};
        _:Reason -> {error, format_error(Reason)}
    end.

pool_info_tuple(Pool) ->
    Info = pool_info(Pool),
    {
        maps:get(total_connections, Info, 0),
        maps:get(idle_connections, Info, 0),
        maps:get(leased_connections, Info, 0),
        maps:get(waiting_requests, Info, 0)
    }.

checkout(Pool, Target, TimeoutMs, ClientPid) ->
    try
        gen_server:call(Pool, {checkout, normalize_target(Target), TimeoutMs, ClientPid}, TimeoutMs + 1000)
    catch
        exit:{timeout, _} -> {error, pool_timeout};
        exit:{noproc, _} -> {error, pool_stopped};
        _:Reason -> {error, Reason}
    end.

checkin(Pool, LeaseRef, Health) ->
    try
        gen_server:call(Pool, {checkin, LeaseRef, Health}, 5000)
    catch
        _:_ -> ok
    end.

pool_info(Pool) ->
    gen_server:call(Pool, pool_info).

%% gen_server callbacks

init(Opts) ->
    process_flag(trap_exit, true),
    _ = application:ensure_all_started(gun),
    MaxPerTarget = get_opt(max_connections_per_target, Opts, 4),
    MaxTotal = get_opt(max_total_connections, Opts, 16),
    IdleTimeout = get_opt(idle_timeout_ms, Opts, 30000),
    PruneTimer = erlang:send_after(5000, self(), prune_idle),
    {ok, #state{
        max_per_target = MaxPerTarget,
        max_total = MaxTotal,
        idle_timeout_ms = IdleTimeout,
        conns = [],
        connecting = [],
        waiters = [],
        prune_timer = PruneTimer
    }}.

handle_call({checkout, Target, TimeoutMs, ClientPid}, From, State) ->
    Deadline = now_ms() + TimeoutMs,
    case find_idle_conn(Target, State#state.conns) of
        {ok, Entry, OtherConns} ->
            Conn = Entry#conn_entry.conn,
            case is_conn_healthy(Conn) of
                true ->
                    LeaseRef = make_ref(),
                    ClientMon = erlang:monitor(process, ClientPid),
                    LeasedEntry = Entry#conn_entry{
                        state = {leased, LeaseRef, ClientPid, ClientMon},
                        idle_since = 0
                    },
                    {reply, {ok, Conn, LeaseRef}, State#state{conns = [LeasedEntry | OtherConns]}};
                false ->
                    gun:close(Conn),
                    stop_owner(Entry#conn_entry.owner_pid),
                    demonitor_safe(Entry#conn_entry.gun_mon),
                    handle_checkout_create(Target, TimeoutMs, Deadline, ClientPid, From,
                        State#state{conns = OtherConns})
            end;
        none ->
            handle_checkout_create(Target, TimeoutMs, Deadline, ClientPid, From, State)
    end;

handle_call({checkin, LeaseRef, Health}, _From, State) ->
    NewState = do_checkin(LeaseRef, Health, State),
    {reply, ok, NewState};

handle_call(pool_info, _From, State) ->
    Total = length(State#state.conns) + length(State#state.connecting),
    Idle = length([C || C <- State#state.conns, C#conn_entry.state =:= idle]),
    Leased = Total - Idle,
    Waiting = length(State#state.waiters),
    Info = #{
        total_connections => Total,
        idle_connections => Idle,
        leased_connections => Leased,
        waiting_requests => Waiting
    },
    {reply, Info, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(prune_idle, State) ->
    Now = now_ms(),
    IdleTimeout = State#state.idle_timeout_ms,
    {Kept, Pruned} = lists:partition(fun(C) ->
        case C#conn_entry.state of
            idle -> (Now - C#conn_entry.idle_since) =< IdleTimeout;
            _ -> true
        end
    end, State#state.conns),
    lists:foreach(fun(C) ->
        gun:close(C#conn_entry.conn),
        stop_owner(C#conn_entry.owner_pid),
        demonitor_safe(C#conn_entry.gun_mon)
    end, Pruned),
    PruneTimer = erlang:send_after(5000, self(), prune_idle),
    {noreply, State#state{conns = Kept, prune_timer = PruneTimer}};

handle_info({waiter_timeout, WaiterRef}, State) ->
    case lists:partition(fun(W) -> W#waiter.from =:= WaiterRef end, State#state.waiters) of
        {[TimedOutWaiter], RemainingWaiters} ->
            demonitor_safe(TimedOutWaiter#waiter.client_mon),
            gen_server:reply(TimedOutWaiter#waiter.from, {error, pool_timeout}),
            {noreply, State#state{waiters = RemainingWaiters}};
        _ ->
            {noreply, State}
    end;

handle_info({connecting_timeout, Ref}, State) ->
    case take_connecting(Ref, State#state.connecting) of
        {ok, Connector, Remaining} ->
            maybe_reply(Connector#connecting.from, {error, pool_timeout}),
            demonitor_safe(Connector#connecting.client_mon),
            Kept = Connector#connecting{from = undefined, client_mon = undefined},
            {noreply, State#state{connecting = [Kept | Remaining]}};
        none ->
            {noreply, State}
    end;

handle_info({connect_result, Ref, Result}, State) ->
    case take_connecting(Ref, State#state.connecting) of
        {ok, Connector, Remaining} ->
            demonitor_safe(Connector#connecting.worker_mon),
            erlang:cancel_timer(Connector#connecting.timer_ref),
            case Result of
                {ok, Conn, GunMon} ->
                    case Connector#connecting.from of
                        undefined ->
                            gun:close(Conn),
                            stop_owner(Connector#connecting.worker_pid),
                            demonitor_safe(GunMon),
                            {noreply, maybe_serve_waiter(State#state{connecting = Remaining})};
                        From ->
                            case now_ms() < Connector#connecting.deadline andalso
                                 is_process_alive(Connector#connecting.client_pid) of
                                true ->
                                    LeaseRef = make_ref(),
                                    Entry = #conn_entry{
                                        conn = Conn,
                                        gun_mon = GunMon,
                                        owner_pid = Connector#connecting.worker_pid,
                                        target = Connector#connecting.target,
                                        state = {leased, LeaseRef, Connector#connecting.client_pid,
                                                 Connector#connecting.client_mon},
                                        idle_since = 0,
                                        created_at = now_ms()
                                    },
                                    gen_server:reply(From, {ok, Conn, LeaseRef}),
                                    {noreply, maybe_serve_waiter(State#state{
                                        conns = [Entry | State#state.conns],
                                        connecting = Remaining
                                    })};
                                false ->
                                    gun:close(Conn),
                                    stop_owner(Connector#connecting.worker_pid),
                                    demonitor_safe(GunMon),
                                    maybe_reply(From, {error, pool_timeout}),
                                    demonitor_safe(Connector#connecting.client_mon),
                                    {noreply, maybe_serve_waiter(State#state{connecting = Remaining})}
                            end
                    end;
                {error, Reason} ->
                    maybe_reply(Connector#connecting.from, {error, Reason}),
                    demonitor_safe(Connector#connecting.client_mon),
                    {noreply, maybe_serve_waiter(State#state{connecting = Remaining})}
            end;
        none ->
            {noreply, State}
    end;

handle_info({'DOWN', Mon, process, _Pid, _Reason}, State) ->
    %% Check if this was a client process
    case find_leased_by_client_mon(Mon, State#state.conns) of
        {ok, Entry, OtherConns} ->
            %% Client holding lease died! Close connection to ensure no stale data.
            gun:close(Entry#conn_entry.conn),
            stop_owner(Entry#conn_entry.owner_pid),
            demonitor_safe(Entry#conn_entry.gun_mon),
            NewState = State#state{conns = OtherConns},
            {noreply, maybe_serve_waiter(NewState)};
        none ->
            %% Check if it was a waiter client
            case lists:partition(fun(W) -> W#waiter.client_mon =:= Mon end, State#state.waiters) of
                {[DeadWaiter], RemainingWaiters} ->
                    erlang:cancel_timer(DeadWaiter#waiter.timer_ref),
                    {noreply, State#state{waiters = RemainingWaiters}};
                _ ->
                    case take_connecting_by_worker_mon(Mon, State#state.connecting) of
                        {ok, Connector, RemainingConnecting} ->
                            maybe_reply(Connector#connecting.from, {error, connector_stopped}),
                            demonitor_safe(Connector#connecting.client_mon),
                            {noreply, maybe_serve_waiter(State#state{connecting = RemainingConnecting})};
                        none ->
                    case take_connecting_by_client_mon(Mon, State#state.connecting) of
                        {ok, Connector, RemainingConnecting} ->
                            {noreply, State#state{connecting = [Connector#connecting{
                                from = undefined,
                                client_mon = undefined
                            } | RemainingConnecting]}};
                        none ->
                    %% Check if it was a gun connection process
                    case find_by_gun_mon(Mon, State#state.conns) of
                        {ok, Entry, OtherConns} ->
                            %% A remote Gun death is a terminal path for the
                            %% parked owner as well as for the connection.
                            %% Stop it before dropping the entry so it cannot
                            %% retain the pool's owner lease indefinitely.
                            stop_owner(Entry#conn_entry.owner_pid),
                            case Entry#conn_entry.state of
                                {leased, _, ClientPid, ClientMon} ->
                                    demonitor_safe(ClientMon),
                                    ClientPid ! {gun_down_from_pool, Entry#conn_entry.conn};
                                _ -> ok
                            end,
                            NewState = State#state{conns = OtherConns},
                            {noreply, maybe_serve_waiter(NewState)};
                        none ->
                            {noreply, State}
                    end
                    end
                    end
            end
    end;

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    catch erlang:cancel_timer(State#state.prune_timer),
    lists:foreach(fun(C) ->
        demonitor_safe(C#conn_entry.gun_mon),
        stop_owner(C#conn_entry.owner_pid),
        case C#conn_entry.state of
            {leased, _, _, ClientMon} -> demonitor_safe(ClientMon);
            _ -> ok
        end,
        catch gun:close(C#conn_entry.conn)
    end, State#state.conns),
    lists:foreach(fun(W) ->
        catch erlang:cancel_timer(W#waiter.timer_ref),
        demonitor_safe(W#waiter.client_mon),
        catch gen_server:reply(W#waiter.from, {error, pool_stopped})
    end, State#state.waiters),
    lists:foreach(fun(C) ->
        catch erlang:cancel_timer(C#connecting.timer_ref),
        demonitor_safe(C#connecting.client_mon),
        demonitor_safe(C#connecting.worker_mon),
        catch exit(C#connecting.worker_pid, kill),
        maybe_reply(C#connecting.from, {error, pool_stopped})
    end, State#state.connecting),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal helpers

handle_checkout_create(Target, TimeoutMs, Deadline, ClientPid, From, State) ->
    TargetConns = count_target_conns(Target, State#state.conns)
        + count_target_connecting(Target, State#state.connecting),
    TotalConns = length(State#state.conns) + length(State#state.connecting),
    if
        TargetConns < State#state.max_per_target andalso TotalConns < State#state.max_total ->
            start_connector(Target, TimeoutMs, Deadline, ClientPid, From, State);
        TimeoutMs > 0 andalso length(State#state.waiters) < State#state.max_total ->
            RemainingMs = erlang:max(Deadline - now_ms(), 1),
            TimerRef = erlang:send_after(RemainingMs, self(), {waiter_timeout, From}),
            ClientMon = erlang:monitor(process, ClientPid),
            Waiter = #waiter{
                from = From,
                target = Target,
                client_pid = ClientPid,
                client_mon = ClientMon,
                deadline = Deadline,
                timer_ref = TimerRef
            },
            {noreply, State#state{waiters = State#state.waiters ++ [Waiter]}};
        TimeoutMs > 0 ->
            {reply, {error, pool_limit_reached}, State};
        true ->
            {reply, {error, pool_limit_reached}, State}
    end.

start_connector(Target, TimeoutMs, Deadline, ClientPid, From, State) ->
    Pool = self(),
    Ref = make_ref(),
    {WorkerPid, WorkerMon} = spawn_monitor(fun() ->
        Result = open_gun_conn(Target, TimeoutMs),
        Pool ! {connect_result, Ref, Result},
        keep_connection_owner(Result)
    end),
    ClientMon = erlang:monitor(process, ClientPid),
    TimerRef = erlang:send_after(erlang:max(Deadline - now_ms(), 1), self(),
                                 {connecting_timeout, Ref}),
    Connector = #connecting{
        ref = Ref,
        target = Target,
        from = From,
        client_pid = ClientPid,
        client_mon = ClientMon,
        deadline = Deadline,
        worker_pid = WorkerPid,
        worker_mon = WorkerMon,
        timer_ref = TimerRef
    },
    {noreply, State#state{connecting = [Connector | State#state.connecting]}}.

do_checkin(LeaseRef, Health, State) ->
    case find_leased_by_ref(LeaseRef, State#state.conns) of
        {ok, Entry, OtherConns} ->
            {leased, LeaseRef, _ClientPid, ClientMon} = Entry#conn_entry.state,
            demonitor_safe(ClientMon),
            Conn = Entry#conn_entry.conn,
            case Health of
                ok ->
                    case is_conn_healthy(Conn) of
                        true ->
                            Target = Entry#conn_entry.target,
                            case pop_matching_waiter(Target, State#state.waiters) of
                                {ok, Waiter, RemainingWaiters} ->
                                    erlang:cancel_timer(Waiter#waiter.timer_ref),
                                    NewLeaseRef = make_ref(),
                                    NewClientMon = Waiter#waiter.client_mon,
                                    LeasedAgain = Entry#conn_entry{
                                        state = {leased, NewLeaseRef, Waiter#waiter.client_pid, NewClientMon},
                                        idle_since = 0
                                    },
                                    gen_server:reply(Waiter#waiter.from, {ok, Conn, NewLeaseRef}),
                                    State#state{conns = [LeasedAgain | OtherConns], waiters = RemainingWaiters};
                                none ->
                                    IdleEntry = Entry#conn_entry{
                                        state = idle,
                                        idle_since = now_ms()
                                    },
                                    State#state{conns = [IdleEntry | OtherConns]}
                            end;
                        false ->
                            gun:close(Conn),
                            stop_owner(Entry#conn_entry.owner_pid),
                            demonitor_safe(Entry#conn_entry.gun_mon),
                            maybe_serve_waiter(State#state{conns = OtherConns})
                    end;
                _NotOk ->
                    gun:close(Conn),
                    stop_owner(Entry#conn_entry.owner_pid),
                    demonitor_safe(Entry#conn_entry.gun_mon),
                    maybe_serve_waiter(State#state{conns = OtherConns})
            end;
        none ->
            State
    end.

maybe_serve_waiter(State) ->
    case find_servable_waiter(State#state.waiters, State#state.conns, State#state.connecting,
                              State#state.max_per_target, State#state.max_total, []) of
        {ok, Waiter, RemainingWaiters} ->
            Target = Waiter#waiter.target,
            erlang:cancel_timer(Waiter#waiter.timer_ref),
            RemainingMs = erlang:max(Waiter#waiter.deadline - now_ms(), 100),
            start_connector(Target, RemainingMs, Waiter#waiter.deadline,
                            Waiter#waiter.client_pid, Waiter#waiter.from,
                            State#state{waiters = RemainingWaiters});
        none ->
            State
    end.

find_servable_waiter([], _Conns, _Connecting, _MaxPerTarget, _MaxTotal, _Acc) -> none;
find_servable_waiter([W | Rest], Conns, Connecting, MaxPerTarget, MaxTotal, Acc) ->
    TotalConns = length(Conns) + length(Connecting),
    TargetConns = count_target_conns(W#waiter.target, Conns)
        + count_target_connecting(W#waiter.target, Connecting),
    if
        TargetConns < MaxPerTarget andalso TotalConns < MaxTotal ->
            {ok, W, lists:reverse(Acc) ++ Rest};
        true ->
            find_servable_waiter(Rest, Conns, Connecting, MaxPerTarget, MaxTotal, [W | Acc])
    end.

pop_matching_waiter(Target, Waiters) ->
    pop_matching_waiter(Target, Waiters, []).

pop_matching_waiter(_Target, [], _Acc) -> none;
pop_matching_waiter(Target, [W | Rest], Acc) ->
    if
        W#waiter.target =:= Target ->
            {ok, W, lists:reverse(Acc) ++ Rest};
        true ->
            pop_matching_waiter(Target, Rest, [W | Acc])
    end.

open_gun_conn(Target, TimeoutMs) ->
    Host = Target#target.host,
    Port = Target#target.port,
    TlsMode = Target#target.tls_mode,
    CaFile = Target#target.ca_file,
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
            max_header_block_size => 16384,
            max_trailer_block_size => 16384
        }
    },
    case gun:open(binary_to_list(Host), Port, GunOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, erlang:max(TimeoutMs, 100)) of
                {ok, _Protocol} ->
                    %% Gun links the connection to the opener. The connector
                    %% worker is short-lived, so detach that link before the
                    %% lease is handed to the pool.
                    unlink(Conn),
                    GunMon = erlang:monitor(process, Conn),
                    {ok, Conn, GunMon};
                {error, Reason} ->
                    gun:close(Conn),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

keep_connection_owner({ok, _Conn, _GunMon}) ->
    receive stop -> ok end;
keep_connection_owner({error, _}) -> ok.

stop_owner(undefined) -> ok;
stop_owner(Pid) when is_pid(Pid) -> Pid ! stop, ok;
stop_owner(_) -> ok.

is_conn_healthy(Conn) ->
    case is_process_alive(Conn) of
        false -> false;
        true ->
            try gun:info(Conn) of
                #{state_name := connected} -> true;
                _ -> false
            catch
                _:_ -> false
            end
    end.

find_idle_conn(Target, Conns) ->
    find_idle_conn(Target, Conns, []).

find_idle_conn(_Target, [], _Acc) -> none;
find_idle_conn(Target, [C | Rest], Acc) ->
    if
        C#conn_entry.target =:= Target andalso C#conn_entry.state =:= idle ->
            {ok, C, lists:reverse(Acc) ++ Rest};
        true ->
            find_idle_conn(Target, Rest, [C | Acc])
    end.

find_leased_by_ref(LeaseRef, Conns) ->
    find_leased_by_ref(LeaseRef, Conns, []).

find_leased_by_ref(_Ref, [], _Acc) -> none;
find_leased_by_ref(LeaseRef, [C | Rest], Acc) ->
    case C#conn_entry.state of
        {leased, LeaseRef, _, _} ->
            {ok, C, lists:reverse(Acc) ++ Rest};
        _ ->
            find_leased_by_ref(LeaseRef, Rest, [C | Acc])
    end.

find_leased_by_client_mon(Mon, Conns) ->
    find_leased_by_client_mon(Mon, Conns, []).

find_leased_by_client_mon(_Mon, [], _Acc) -> none;
find_leased_by_client_mon(Mon, [C | Rest], Acc) ->
    case C#conn_entry.state of
        {leased, _, _, Mon} ->
            {ok, C, lists:reverse(Acc) ++ Rest};
        _ ->
            find_leased_by_client_mon(Mon, Rest, [C | Acc])
    end.

find_by_gun_mon(Mon, Conns) ->
    find_by_gun_mon(Mon, Conns, []).

find_by_gun_mon(_Mon, [], _Acc) -> none;
find_by_gun_mon(Mon, [C | Rest], Acc) ->
    if
        C#conn_entry.gun_mon =:= Mon ->
            {ok, C, lists:reverse(Acc) ++ Rest};
        true ->
            find_by_gun_mon(Mon, Rest, [C | Acc])
    end.

count_target_conns(Target, Conns) ->
    length([C || C <- Conns, C#conn_entry.target =:= Target]).

count_target_connecting(Target, Connecting) ->
    length([C || C <- Connecting, C#connecting.target =:= Target]).

take_connecting(_Ref, []) -> none;
take_connecting(Ref, [C | Rest]) when C#connecting.ref =:= Ref ->
    {ok, C, Rest};
take_connecting(Ref, [C | Rest]) ->
    case take_connecting(Ref, Rest) of
        {ok, Found, Remaining} -> {ok, Found, [C | Remaining]};
        none -> none
    end.

take_connecting_by_client_mon(_Mon, []) -> none;
take_connecting_by_client_mon(Mon, [C | Rest]) when C#connecting.client_mon =:= Mon ->
    {ok, C, Rest};
take_connecting_by_client_mon(Mon, [C | Rest]) ->
    case take_connecting_by_client_mon(Mon, Rest) of
        {ok, Found, Remaining} -> {ok, Found, [C | Remaining]};
        none -> none
    end.

take_connecting_by_worker_mon(_Mon, []) -> none;
take_connecting_by_worker_mon(Mon, [C | Rest]) when C#connecting.worker_mon =:= Mon ->
    {ok, C, Rest};
take_connecting_by_worker_mon(Mon, [C | Rest]) ->
    case take_connecting_by_worker_mon(Mon, Rest) of
        {ok, Found, Remaining} -> {ok, Found, [C | Remaining]};
        none -> none
    end.

maybe_reply(undefined, _Reply) -> ok;
maybe_reply(From, Reply) -> gen_server:reply(From, Reply).

normalize_target(#target{} = T) -> T;
normalize_target(#{host := H, port := P, tls_mode := M, ca_file := C}) ->
    #target{host = H, port = P, tls_mode = M, ca_file = C};
normalize_target({H, P, M, C}) ->
    #target{host = H, port = P, tls_mode = M, ca_file = C}.

get_opt(Key, Map, Default) when is_map(Map) ->
    maps:get(Key, Map, Default);
get_opt(Key, List, Default) when is_list(List) ->
    proplists:get_value(Key, List, Default);
get_opt(_Key, _TupleOrOther, Default) ->
    Default.

demonitor_safe(undefined) -> ok;
demonitor_safe(Mon) when is_reference(Mon) ->
    erlang:demonitor(Mon, [flush]),
    ok.

now_ms() -> erlang:monotonic_time(millisecond).

format_error(Reason) when is_binary(Reason) -> Reason;
format_error(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format_error(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
