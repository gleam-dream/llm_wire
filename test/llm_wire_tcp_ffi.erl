-module(llm_wire_tcp_ffi).

-export([
    listen/1,
    accept/2,
    connect/3,
    send/2,
    recv/3,
    close/1,
    get_port/1
]).

listen(Port) ->
    case gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]) of
        {ok, ListenSocket} ->
            case inet:port(ListenSocket) of
                {ok, AssignedPort} -> {ok, {ListenSocket, AssignedPort}};
                {error, Reason} ->
                    gen_tcp:close(ListenSocket),
                    {error, atom_to_binary(Reason, utf8)}
            end;
        {error, Reason} ->
            {error, atom_to_binary(Reason, utf8)}
    end.

accept(ListenSocket, Timeout) ->
    case gen_tcp:accept(ListenSocket, Timeout) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

connect(HostBin, Port, Timeout) ->
    HostStr = binary_to_list(HostBin),
    case gen_tcp:connect(HostStr, Port, [binary, {active, false}], Timeout) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

send(Socket, DataBin) ->
    case gen_tcp:send(Socket, DataBin) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

recv(Socket, Length, Timeout) ->
    case gen_tcp:recv(Socket, Length, Timeout) of
        {ok, Bin} -> {ok, Bin};
        {error, closed} -> {error, <<"closed">>};
        {error, timeout} -> {error, <<"timeout">>};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

close(Socket) ->
    gen_tcp:close(Socket),
    nil.

get_port(ListenSocket) ->
    case inet:port(ListenSocket) of
        {ok, Port} -> {ok, Port};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.
