-module(retry_fixture).
-export([endpoint/0]).

endpoint() ->
    unicode:characters_to_binary(os:getenv("LLM_WIRE_RETRY_TEST_ENDPOINT")).
