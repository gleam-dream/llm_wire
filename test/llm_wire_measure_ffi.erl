%% Local validation only. Snapshot pattern inspired by Apache-2.0 HTTP Gun;
%% provenance is recorded in docs/evidence/http-gun/donor-source.json.
-module(llm_wire_measure_ffi).
-export([now/0, sample/0]).
now() -> erlang:monotonic_time(microsecond).
sample() ->
    Rows = [
        I
     || P <- processes(),
        I <- [process_info(P, [memory, message_queue_len])],
        I =/= undefined
    ],
    Memory = [proplists:get_value(memory, R) || R <- Rows],
    Queues = [proplists:get_value(message_queue_len, R) || R <- Rows],
    {
        erlang:memory(total),
        lists:max([0 | Memory]),
        lists:sum(Queues),
        lists:max([0 | Queues]),
        length(Rows),
        length(erlang:ports())
    }.
