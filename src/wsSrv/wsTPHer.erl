-module(wsTPHer).

-behaviour(wsHer).

-include("wsCom.hrl").
-include_lib("kernel/include/file.hrl").

-export([
   handle/3
]).

-export([
   chunk_loop/1
]).

-spec handle(Method :: wsMethod(), Path :: wsPath(), WsReq :: wsReq()) -> wsHer:response().
handle('GET', <<"/hello/world">>, WsReq) ->
   io:format("IMY************XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX ~n receive WsReq: ~p~n", [WsReq]),
   %% Reply with a normal response.
   %timer:sleep(1000),
   {ok, [], <<"Hello World!">>};

handle('GET', <<"/hello">>, WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Fetch a GET argument from the URL.
   Name = proplists:get_value(<<"name">>, WsReq, <<"undefined">>),
   {ok, [], <<"Hello ", Name/binary>>};

handle('POST', <<"hello">>, WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Fetch a POST argument from the POST body.
   Name = proplists:get_value(<<"name">>, WsReq, <<"undefined">>),
   %% Fetch and decode
   City = proplists:get_value(<<"city">>, WsReq, <<"undefined">>),
   {ok, [], <<"Hello ", Name/binary, " of ", City/binary>>};

handle('GET', [<<"hello">>, <<"iolist">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Iolists will be kept as iolists all the way to the socket.
   Name = proplists:get_value(<<"name">>, WsReq),
   {ok, [], [<<"Hello ">>, Name]};

handle('GET', [<<"type">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   Name = proplists:get_value(<<"name">>, WsReq),
   %% Fetch a header.
   case proplists:get_value(<<"Accept">>, WsReq, <<"text/plain">>) of
      <<"text/plain">> ->
         {ok, [{<<"content-type">>, <<"text/plain; charset=ISO-8859-1">>}],
            <<"name: ", Name/binary>>};
      <<"application/json">> ->
         {ok, [{<<"content-type">>,
            <<"application/json; charset=ISO-8859-1">>}],
            <<"{\"name\" : \"", Name/binary, "\"}">>}
   end;

handle('GET', [<<"headers.html">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Set custom headers, for example 'Content-Type'
   {ok, [{<<"X-Custom">>, <<"foobar">>}], <<"see headers">>};

%% See note in function doc re: overriding Elli's default behaviour
%% via Connection and Content-Length headers.
handle('GET', [<<"user">>, <<"defined">>, <<"behaviour">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {304, [{<<"Connection">>, <<"close">>},
      {<<"Content-Length">>, <<"123">>}], <<"ignored">>};

handle('GET', [<<"user">>, <<"content-length">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {200, [{<<"Content-Length">>, 123}], <<"foobar">>};

handle('GET', [<<"crash">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Throwing an exception results in a 500 response and
   %% request_throw being called
   throw(foobar);

handle('GET', [<<"decoded-hello">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Fetch a URI decoded GET argument from the URL.
   Name = proplists:get_value(<<"name">>, WsReq, <<"undefined">>),
   {ok, [], <<"Hello ", Name/binary>>};

handle('GET', [<<"decoded-list">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {ok, [], <<"Hello">>};


handle('GET', [<<"sendfile">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Returning {file, "/path/to/file"} instead of the body results
   %% in Elli using sendfile.
   F = "README.md",
   {ok, [], {file, F}};

handle('GET', [<<"send_no_file">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Returning {file, "/path/to/file"} instead of the body results
   %% in Elli using sendfile.
   F = "README",
   {ok, [], {file, F}};

handle('GET', [<<"sendfile">>, <<"error">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   F = "test",
   {ok, [], {file, F}};

handle('GET', [<<"sendfile">>, <<"range">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Read the Range header of the request and use the normalized
   %% range with sendfile, otherwise send the entire file when
   %% no range is present, or respond with a 416 if the range is invalid.
   F = "README.md",
   {ok, [], {file, F, get_range(WsReq)}};

handle('GET', [<<"compressed">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Body with a byte size over 1024 are automatically gzipped by
   %% elli_middleware_compress
   {ok, binary:copy(<<"Hello World!">>, 86)};

handle('GET', [<<"compressed-io_list">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Body with a iolist size over 1024 are automatically gzipped by
   %% elli_middleware_compress
   {ok, lists:duplicate(86, [<<"Hello World!">>])};


handle('HEAD', [<<"head">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {200, [], <<"body must be ignored">>};

handle('GET', [<<"chunked">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Start a chunked response for streaming real-time events to the
   %% browser.
   %%
   %% Calling elli_request:send_chunk(ChunkRef, Body) will send that
   %% part to the client. elli_request:close_chunk(ChunkRef) will
   %% close the response.
   %%
   %% Return immediately {chunk, Headers} to signal we want to chunk.
   spawn(fun() -> ?MODULE:chunk_loop(not_support) end),
   {chunk, [{<<"Content-Type">>, <<"text/event-stream">>}]};

handle('GET', [<<"shorthand">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {200, <<"hello">>};

handle('GET', [<<"ip">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {<<"200 OK">>, wsNet:peername(WsReq)};

handle('GET', [<<"304">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% A "Not Modified" response is exactly like a normal response (so
   %% Content-Length is included), but the body will not be sent.
   {304, [{<<"Etag">>, <<"foobar">>}], <<"Ignored">>};

handle('GET', [<<"302">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {302, [{<<"Location">>, <<"/hello/world">>}], <<>>};

handle('GET', [<<"403">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   %% Exceptions formatted as return codes can be used to
   %% short-circuit a response, for example in case of
   %% authentication/authorization
   throw({403, [], <<"Forbidden">>});

handle('GET', [<<"invalid_return">>], WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {invalid_return};

handle(_, _, WsReq) ->
   io:format("receive WsReq: ~p~n", [WsReq]),
   {404, [], <<"Not Found">>}.


%% @doc Parse the `Range' header from the request.
%% The result is either a `byte_range_set()' or the atom `parse_error'.
%% Use {@link elli_util:normalize_range/2} to get a validated, normalized range.
-spec get_range(elli:wsReq()) -> [http_range()] | parse_error.
get_range(#wsReq{headers = Headers}) ->
   case proplists:get_value(<<"range">>, Headers) of
      <<"bytes=", RangeSetBin/binary>> ->
         parse_range_set(RangeSetBin);
      _ -> []
   end.


-spec parse_range_set(Bin :: binary()) -> [http_range()] | parse_error.
parse_range_set(<<ByteRangeSet/binary>>) ->
   RangeBins = binary:split(ByteRangeSet, <<",">>, [global]),
   Parsed = [parse_range(remove_whitespace(RangeBin))
      || RangeBin <- RangeBins],
   case lists:member(parse_error, Parsed) of
      true -> parse_error;
      false -> Parsed
   end.

-spec remove_whitespace(binary()) -> binary().
remove_whitespace(Bin) ->
   binary:replace(Bin, <<" ">>, <<>>, [global]).

-type http_range() :: {First :: non_neg_integer(), Last :: non_neg_integer()}
| {offset, Offset :: non_neg_integer()}
| {suffix, Length :: pos_integer()}.

-spec parse_range(Bin :: binary()) -> http_range() | parse_error.
parse_range(<<$-, SuffixBin/binary>>) ->
   %% suffix-byte-range
   try {suffix, binary_to_integer(SuffixBin)}
   catch
      error:badarg -> parse_error
   end;
parse_range(<<ByteRange/binary>>) ->
   case binary:split(ByteRange, <<"-">>) of
      %% byte-range without last-byte-pos
      [FirstBytePosBin, <<>>] ->
         try {offset, binary_to_integer(FirstBytePosBin)}
         catch
            error:badarg -> parse_error
         end;
      %% full byte-range
      [FirstBytePosBin, LastBytePosBin] ->
         try {bytes,
            binary_to_integer(FirstBytePosBin),
            binary_to_integer(LastBytePosBin)}
         catch
            error:badarg -> parse_error
         end;
      _ -> parse_error
   end.

%% @doc Send 10 separate chunks to the client.
%% @equiv chunk_loop(Ref, 10)
chunk_loop(Ref) ->
   chunk_loop(Ref, 10).

%% @doc If `N > 0', send a chunk to the client, checking for errors,
%% as the user might have disconnected.
%% When `N == 0', call {@link elli_request:close_chunk/1.
%% elli_request:close_chunk(Ref)}.
chunk_loop(Ref, 0) ->
   close_chunk(Ref);
chunk_loop(Ref, N) ->
   timer:sleep(10),

   case send_chunk(Ref, [<<"chunk">>, integer_to_binary(N)]) of
      ok -> ok;
      {error, Reason} -> ?wsErr("error in sending chunk: ~p~n", [Reason])
   end,
   chunk_loop(Ref, N - 1).

%% @doc Return a reference that can be used to send chunks to the client.
%% If the protocol does not support it, return `{error, not_supported}'.
% chunk_ref(#wsReq{}) ->
%    {error, not_supported}.

%% @doc Explicitly close the chunked connection.
%% Return `{error, closed}' if the client already closed the connection.
%% @equiv send_chunk(Ref, close)
close_chunk(Ref) ->
   send_chunk(Ref, close).

% %% @doc Send a chunk asynchronously.
% async_send_chunk(Ref, Data) ->
%    Ref ! {chunk, Data}.

%% @doc Send a chunk synchronously.
%% If the referenced process is dead, return early with `{error, closed}',
%% instead of timing out.
send_chunk(Ref, Data) ->
   ?CASE(is_ref_alive(Ref),
      send_chunk(Ref, Data, 5000),
      {error, closed}).

is_ref_alive(Ref) ->
   ?CASE(node(Ref) =:= node(),
      is_process_alive(Ref),
      erpc:call(node(Ref), erlang, is_process_alive, [Ref])).

send_chunk(Ref, Data, Timeout) ->
   Ref ! {chunk, Data, self()},
   receive
      {Ref, ok} ->
         ok;
      {Ref, {error, Reason}} ->
         {error, Reason}
   after Timeout ->
      {error, timeout}
   end.