-module(llm_wire_cassette_ffi).
-export([read_bounded/2]).

read_bounded(Path, Bytes) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, File} ->
            try
                case file:read(File, Bytes) of
                    {ok, Data} -> {ok, Data};
                    eof -> {ok, <<>>};
                    {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
                end
            after
                file:close(File)
            end;
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.
