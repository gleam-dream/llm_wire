%% Opt-in live recording only: reads a provider key from the environment and
%% the scenario names from the command line. Never prints a value.
-module(llm_wire_live_ffi).
-export([getenv/1, arguments/0]).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

arguments() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].
