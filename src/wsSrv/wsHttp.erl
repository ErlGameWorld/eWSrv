-module(wsHttp).

-include_lib("eNet/include/eNet.hrl").
-include("wsCom.hrl").

-export([
   start_link/1
   , sendResponse/5
   , sendFile/5
   %% Exported for looping with a fully-qualified module name
   , chunkLoop/1
   , spellHeaders/1
   , splitArgs/1
   , closeOrKeepAlive/2
   , maybeSendContinue/2
]).

%% eNet callback
-export([newConn/2]).

-export([
   init_it/2
   , system_code_change/4
   , system_continue/3
   , system_get_state/1
   , system_terminate/4
]).

newConn(_Sock, ConnArgs) ->
   ?MODULE:start_link(ConnArgs).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% genActor  start %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec(start_link(atom()) -> {ok, pid()} | ignore | {error, term()}).
start_link(ConnArgs) ->
   proc_lib:start_link(?MODULE, init_it, [self(), ConnArgs], infinity, []).

init_it(Parent, Args) ->
   process_flag(trap_exit, true),
   modInit(Parent, Args).

-spec system_code_change(term(), module(), undefined | term(), term()) -> {ok, term()}.
system_code_change(State, _Module, _OldVsn, _Extra) ->
   {ok, State}.

-spec system_continue(pid(), [], {module(), atom(), pid(), term()}) -> ok.
system_continue(_Parent, _Debug, {Parent, State}) ->
   loop(Parent, State).

-spec system_get_state(term()) -> {ok, term()}.
system_get_state(State) ->
   {ok, State}.

-spec system_terminate(term(), pid(), [], term()) -> none().
system_terminate(Reason, _Parent, _Debug, State) ->
   terminate(Reason, State).

modInit(Parent, Args) ->
   case init(Args) of
      {ok, State} ->
         proc_lib:init_ack(Parent, {ok, self()}),
         loop(Parent, State);
      {stop, Reason} ->
         proc_lib:init_ack(Parent, {error, Reason}),
         exit(Reason)
   end.

loop(Parent, State) ->
   receive
      {system, From, Request} ->
         sys:handle_system_msg(Request, From, Parent, ?MODULE, [], {Parent, State});
      {'EXIT', Parent, Reason} ->
         terminate(Reason, State);
      Msg ->
         case handleMsg(Msg, State) of
            kpS ->
               loop(Parent, State);
            {ok, NewState} ->
               loop(Parent, NewState);
            {stop, Reason} ->
               terminate(Reason, State)
         end
   end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% genActor  end %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ************************************************  API ***************************************************************

init({WsMod, MaxSize, ChunkedSupp}) ->
   {ok, #wsState{wsMod = WsMod, maxSize = MaxSize, chunkedSupp = ChunkedSupp}}.

handleMsg({tcp, _Socket, Data}, State) ->
   #wsState{stage = Stage, buffer = Buffer, socket = Socket} = State,
   case wsHttpProtocol:request(Stage, <<Buffer/binary, Data/binary>>, Socket, State) of
      {ok, _NewState} = LRet ->
         LRet;
      {done, NewState} ->
         Response = doHandle(NewState),
         #wsState{buffer = Buffer, socket = Socket, temHeader = TemHeader, method = Method} = NewState,
         case doResponse(Response, Socket, TemHeader, Method) of
            keep_alive ->
               case Buffer of
                  <<>> ->
                     {ok, newWsState(NewState)};
                  _ ->
                     handleMsg({tcp, Socket, Buffer}, newWsState(NewState))
               end;
            close ->
               {stop, normal}
         end;
      Err ->
         ?wsErr("recv the http data error ~p~n", [Err]),
         sendBadRequest(Socket),
         {stop, Err}
   end;
handleMsg({tcp_closed, _Socket}, _State) ->
   {stop, normal};
handleMsg({tcp_error, _Socket, Reason}, _State) ->
   ?wsErr("the http tcp socket error ~p~n", [Reason]),
   {stop, tcp_error};

handleMsg({ssl, _Socket, Data}, State) ->
   #wsState{stage = Stage, buffer = Buffer, socket = Socket} = State,
   case wsHttpProtocol:request(Stage, <<Buffer/binary, Data/binary>>, Socket, State) of
      {ok, _NewState} = LRet ->
         LRet;
      {done, NewState} ->
         Response = doHandle(NewState),
         #wsState{buffer = Buffer, temHeader = TemHeader, method = Method} = NewState,
         case doResponse(Response, Socket, TemHeader, Method) of
            keep_alive ->
               case Buffer of
                  <<>> ->
                     {ok, newWsState(NewState)};
                  _ ->
                     handleMsg({ssl, Socket, Buffer}, newWsState(NewState))
               end;
            close ->
               {stop, normal}
         end;
      Err ->
         ?wsErr("recv the http data error ~p~n", [Err]),
         sendBadRequest(Socket),
         {stop, Err}
   end;
handleMsg({ssl_closed, _Socket}, _State) ->
   {stop, normal};
handleMsg({ssl_error, _Socket, Reason}, _State) ->
   ?wsErr("the http ssl socket error ~p~n", [Reason]),
   {stop, ssl_error};
handleMsg({?mSockReady, Sock}, State) ->
   inet:setopts(Sock, [{packet, raw}, {active, true}]),
   {ok, State#wsState{socket = Sock}};
handleMsg({?mSockReady, Sock, SslOpts, SslHSTet}, State) ->
   case ntSslAcceptor:handshake(Sock, SslOpts, SslHSTet) of
      {ok, SslSock} ->
         ssl:setopts(Sock, [{packet, raw}, {active, true}]),
         {ok, State#wsState{socket = SslSock, isSsl = true}};
      _Err ->
         ?wsErr("ssl handshake error ~p~n", [_Err]),
         {stop, handshake_error}
   end;
handleMsg(_Msg, _State) ->
   ?wsErr("~p info receive unexpect msg ~p ~n ", [?MODULE, _Msg]),
   kpS.

terminate(Reason, #wsState{socket = Socket} = _State) ->
   wsNet:close(Socket),
   exit(Reason).

newWsState(WsState) ->
   WsState#wsState{
      stage = reqLine
      , buffer = <<>>
      , wsReq = undefined
      , headerCnt = 0
      , temHeader = []
      , contentLength = undefined
      , temChunked = <<>>
   }.

%% @doc Execute the user callback, translating failure into a proper response.
doHandle(State) ->
   #wsState{wsMod = WsMod, method = Method, path = Path, wsReq = WsReq} = State,
   try WsMod:handle(Method, Path, WsReq) of
      %% {ok,...{file,...}}
      {ok, Headers, {file, Filename}} ->
         {file, 200, Headers, Filename, []};
      {ok, Headers, {file, Filename, Range}} ->
         {file, 200, Headers, Filename, Range};
      %% ok simple
      {ok, Headers, Body} -> {response, 200, Headers, Body};
      {ok, Body} -> {response, 200, [], Body};
      %% Chunk
      {chunk, Headers} -> {chunk, Headers, <<"">>};
      {chunk, Headers, Initial} -> {chunk, Headers, Initial};
      %% File
      {HttpCode, Headers, {file, Filename}} ->
         {file, HttpCode, Headers, Filename, {0, 0}};
      {HttpCode, Headers, {file, Filename, Range}} ->
         {file, HttpCode, Headers, Filename, Range};
      %% Simple
      {HttpCode, Headers, Body} -> {response, HttpCode, Headers, Body};
      {HttpCode, Body} -> {response, HttpCode, [], Body};
      %% Unexpected
      Unexpected ->
         ?wsErr("handle return error WsReq:~p Ret:~p~n", [WsReq, Unexpected]),
         {response, 500, [], <<"Internal server error">>}
   catch
      throw:{ResponseCode, Headers, Body} when is_integer(ResponseCode) ->
         {response, ResponseCode, Headers, Body};
      throw:Exc:Stacktrace ->
         ?wsErr("handle catch throw WsReq:~p R:~p S:~p~n", [WsReq, Exc, Stacktrace]),
         {response, 500, [], <<"Internal server error">>};
      error:Error:Stacktrace ->
         ?wsErr("handle catch error WsReq:~p R:~p S:~p~n", [WsReq, Error, Stacktrace]),
         {response, 500, [], <<"Internal server error">>};
      exit:Exit:Stacktrace ->
         ?wsErr("handle catch exit WsReq:~p R:~p S:~p~n", [WsReq, Exit, Stacktrace]),
         {response, 500, [], <<"Internal server error">>}
   end.

doResponse({response, Code, UserHeaders, Body}, Socket, TemHeader, Method) ->
   Headers = [connection(UserHeaders, TemHeader), contentLength(UserHeaders, Body) | UserHeaders],
   sendResponse(Socket, Method, Code, Headers, Body),
   closeOrKeepAlive(UserHeaders, TemHeader);
doResponse({chunk, UserHeaders, Initial}, Socket, TemHeader, Method) ->
   ResponseHeaders = [transferEncoding(UserHeaders), connection(UserHeaders, TemHeader) | UserHeaders],
   sendResponse(Socket, Method, 200, ResponseHeaders, <<>>),
   Initial =:= <<"">> orelse sendChunk(Socket, Initial),
   case startChunkLoop(Socket) of
      {error, client_closed} -> client;
      ok -> server
   end,
   close;
doResponse({file, ResponseCode, UserHeaders, Filename, Range}, Socket, TemHeader, Method) ->
   ResponseHeaders = [connection(UserHeaders, TemHeader) | UserHeaders],
   case wsUtil:fileSize(Filename) of
      {error, _FileError} ->
         sendSrvError(Socket),
         {stop, file_error};
      Size ->
         Ret =
            case wsUtil:normalizeRange(Range, Size) of
               undefined ->
                  sendFile(Socket, ResponseCode, [{?CONTENT_LENGTH_HEADER, Size} | ResponseHeaders], Filename, {0, 0});
               {Offset, Length} ->
                  ERange = wsUtil:encodeRange({Offset, Length}, Size),
                  sendFile(Socket, 206, lists:append(ResponseHeaders, [{?CONTENT_LENGTH_HEADER, Length}, {<<"Content-Range">>, ERange}]), Filename, {Offset, Length});
               invalid_range ->
                  ERange = wsUtil:encodeRange(invalid_range, Size),
                  sendResponse(Socket, Method, 416, lists:append(ResponseHeaders, [{<<"Content-Length">>, 0}, {<<"Content-Range">>, ERange}]), <<>>),
                  {error, range}
            end,
         case Ret of
            ok ->
               closeOrKeepAlive(UserHeaders, TemHeader);
            _Err ->
               {stop, Ret}
         end
   end.

%% @doc Generate a HTTP response and send it to the client.
sendResponse(Socket, Method, Code, Headers, UserBody) ->
   Body =
      case Method of
         'HEAD' ->
            <<>>;
         _ ->
            case Code of
               304 ->
                  <<>>;
               204 ->
                  <<>>;
               _ ->
                  UserBody
            end
      end,

   Response = httpResponse(Code, Headers, Body),

   case wsNet:send(Socket, Response) of
      ok ->
         ok;
      _Err ->
         ?wsErr("send_response error ~p~n", [_Err])
   end.

%% @doc Send a HTTP response to the client where the body is the
%% contents of the given file. Assumes correctly set response code
%% and headers.
-spec sendFile(Req, Code, Headers, Filename, Range) -> ok when
   Req :: elli:wsReq(),
   Code :: elli:wsHttpCode(),
   Headers :: elli:wsHeaders(),
   Filename :: file:filename(),
   Range :: wsUtil:range().
sendFile(Socket, Code, Headers, Filename, Range) ->
   ResponseHeaders = httpResponse(Code, Headers, <<>>),
   case file:open(Filename, [read, raw, binary]) of
      {ok, Fd} -> doSendFile(Fd, Range, Socket, ResponseHeaders);
      {error, _FileError} = Err ->
         sendSrvError(Socket),
         Err
   end.

doSendFile(Fd, {Offset, Length}, Socket, Headers) ->
   try wsNet:send(Socket, Headers) of
      ok ->
         case wsNet:sendfile(Fd, Socket, Offset, Length, []) of
            {ok, _BytesSent} -> ok;
            {error, Closed} = LErr when Closed =:= closed orelse Closed =:= enotconn ->
               ?wsErr("send file error"),
               LErr
         end;
      {error, Closed} = LErr when Closed =:= closed orelse Closed =:= enotconn ->
         ?wsErr("send file error"),
         LErr
   after
      file:close(Fd)
   end.

%% @doc To send a response, we must first have received everything the
%% client is sending. If this is not the case, {@link send_bad_request/1}
%% might reset the client connection.
sendBadRequest(Socket) ->
   sendRescueResponse(Socket, 400, <<"Bad Request">>).

sendSrvError(Socket) ->
   sendRescueResponse(Socket, 500, <<"Server Error">>).

sendRescueResponse(Socket, Code, Body) ->
   Response = httpResponse(Code, Body),
   wsNet:send(Socket, Response).

%% CHUNKED-TRANSFER
%% @doc The chunk loop is an intermediary between the socket and the
%% user. We forward anything the user sends until the user sends an
%% empty response, which signals that the connection should be
%% closed. When the client closes the socket, the loop exits.
startChunkLoop(Socket) ->
   %% Set the socket to active so we receive the tcp_closed message
   %% if the client closes the connection
   wsNet:setopts(Socket, [{active, once}]),
   ?MODULE:chunkLoop(Socket).

chunkLoop(Socket) ->
   receive
      {tcp_closed, Socket} ->
         {error, client_closed};
      {chunk, close} ->
         case wsNet:send(Socket, <<"0\r\n\r\n">>) of
            ok ->
               ok;
            {error, Closed} when Closed =:= closed orelse Closed =:= enotconn ->
               {error, client_closed}
         end;
      {chunk, close, From} ->
         case wsNet:send(Socket, <<"0\r\n\r\n">>) of
            ok ->
               From ! {self(), ok},
               ok;
            {error, Closed} when Closed =:= closed orelse Closed =:= enotconn ->
               From ! {self(), {error, closed}},
               ok
         end;
      {chunk, Data} ->
         sendChunk(Socket, Data),
         ?MODULE:chunkLoop(Socket);
      {chunk, Data, From} ->
         case sendChunk(Socket, Data) of
            ok ->
               From ! {self(), ok};
            {error, Closed} when Closed =:= closed orelse Closed =:= enotconn ->
               From ! {self(), {error, closed}}
         end,
         ?MODULE:chunkLoop(Socket)
   after 10000 ->
      ?MODULE:chunkLoop(Socket)
   end.

sendChunk(Socket, Data) ->
   case iolist_size(Data) of
      0 -> ok;
      Size ->
         Response = [integer_to_binary(Size, 16), <<"\r\n">>, Data, <<"\r\n">>],
         wsNet:send(Socket, Response)
   end.

maybeSendContinue(Socket, Headers) ->
   % According to RFC2616 section 8.2.3 an origin server must respond with
   % either a "100 Continue" or a final response code when the client
   % headers contains "Expect:100-continue"
   case lists:keyfind(?EXPECT_HEADER, 1, Headers) of
      <<"100-continue">> ->
         Response = httpResponse(100),
         wsNet:send(Socket, Response);
      _Other ->
         ok
   end.

httpResponse(Code) ->
   httpResponse(Code, <<>>).

httpResponse(Code, Body) ->
   httpResponse(Code, [{?CONTENT_LENGTH_HEADER, size(Body)}], Body).

httpResponse(Code, Headers, Body) ->
   [<<"HTTP/1.1 ">>, status(Code), <<"\r\n">>, spellHeaders(Headers), <<"\r\n">>, Body].

spellHeaders(Headers) ->
   <<<<(toBinStr(Key))/binary, ": ", (toBinStr(Value))/binary, "\r\n">> || {Key, Value} <- Headers>>.

-spec splitArgs(binary()) -> list({binary(), binary() | true}).
splitArgs(<<>>) -> [];
splitArgs(Qs) ->
   Tokens = binary:split(Qs, <<"&">>, [global, trim]),
   [case binary:split(Token, <<"=">>) of [Token] -> {Token, true}; [Name, Value] ->
      {Name, Value} end || Token <- Tokens].

toBinStr(V) when is_integer(V) -> integer_to_binary(V);
toBinStr(V) when is_binary(V) -> V;
toBinStr(V) when is_list(V) -> list_to_binary(V);
toBinStr(V) when is_atom(V) -> atom_to_binary(V).

closeOrKeepAlive(UserHeaders, ReqHeader) ->
   case lists:keyfind(?CONNECTION_HEADER, 1, UserHeaders) of
      {_, <<"Close">>} ->
         close;
      {_, <<"close">>} ->
         close;
      _ ->
         case lists:keyfind(?CONNECTION_HEADER, 1, ReqHeader) of
            {_, <<"Close">>} ->
               close;
            {_, <<"close">>} ->
               close;
            _ ->
               keep_alive
         end
   end.

connection(UserHeaders, ReqHeader) ->
   case lists:keyfind(?CONNECTION_HEADER, 1, UserHeaders) of
      false ->
         case lists:keyfind(?CONNECTION_HEADER, 1, ReqHeader) of
            false ->
               {?CONNECTION_HEADER, <<"Keep-Alive">>};
            Tuple ->
               Tuple
         end;
      _ ->
         []
   end.

contentLength(Headers, Body) ->
   case lists:keyfind(?CONTENT_LENGTH_HEADER, 1, Headers) of
      false ->
         {?CONTENT_LENGTH_HEADER, iolist_size(Body)};
      _ ->
         []
   end.

transferEncoding(Headers) ->
   case lists:keyfind(?TRANSFER_ENCODING_HEADER, 1, Headers) of
      false ->
         {?TRANSFER_ENCODING_HEADER, <<"chunked">>};
      _ ->
         []
   end.

%% HTTP STATUS CODES
status(100) -> <<"100 Continue">>;
status(101) -> <<"101 Switching Protocols">>;
status(102) -> <<"102 Processing">>;
status(200) -> <<"200 OK">>;
status(201) -> <<"201 Created">>;
status(202) -> <<"202 Accepted">>;
status(203) -> <<"203 Non-Authoritative Information">>;
status(204) -> <<"204 No Content">>;
status(205) -> <<"205 Reset Content">>;
status(206) -> <<"206 Partial Content">>;
status(207) -> <<"207 Multi-Status">>;
status(226) -> <<"226 IM Used">>;
status(300) -> <<"300 Multiple Choices">>;
status(301) -> <<"301 Moved Permanently">>;
status(302) -> <<"302 Found">>;
status(303) -> <<"303 See Other">>;
status(304) -> <<"304 Not Modified">>;
status(305) -> <<"305 Use Proxy">>;
status(306) -> <<"306 Switch Proxy">>;
status(307) -> <<"307 Temporary Redirect">>;
status(400) -> <<"400 Bad Request">>;
status(401) -> <<"401 Unauthorized">>;
status(402) -> <<"402 Payment Required">>;
status(403) -> <<"403 Forbidden">>;
status(404) -> <<"404 Not Found">>;
status(405) -> <<"405 Method Not Allowed">>;
status(406) -> <<"406 Not Acceptable">>;
status(407) -> <<"407 Proxy Authentication Required">>;
status(408) -> <<"408 Request Timeout">>;
status(409) -> <<"409 Conflict">>;
status(410) -> <<"410 Gone">>;
status(411) -> <<"411 Length Required">>;
status(412) -> <<"412 Precondition Failed">>;
status(413) -> <<"413 Request Entity Too Large">>;
status(414) -> <<"414 Request-URI Too Long">>;
status(415) -> <<"415 Unsupported Media Type">>;
status(416) -> <<"416 Requested Range Not Satisfiable">>;
status(417) -> <<"417 Expectation Failed">>;
status(418) -> <<"418 I'm a teapot">>;
status(422) -> <<"422 Unprocessable Entity">>;
status(423) -> <<"423 Locked">>;
status(424) -> <<"424 Failed Dependency">>;
status(425) -> <<"425 Unordered Collection">>;
status(426) -> <<"426 Upgrade Required">>;
status(428) -> <<"428 Precondition Required">>;
status(429) -> <<"429 Too Many Requests">>;
status(431) -> <<"431 Request Header Fields Too Large">>;
status(500) -> <<"500 Internal Server Error">>;
status(501) -> <<"501 Not Implemented">>;
status(502) -> <<"502 Bad Gateway">>;
status(503) -> <<"503 Service Unavailable">>;
status(504) -> <<"504 Gateway Timeout">>;
status(505) -> <<"505 HTTP Version Not Supported">>;
status(506) -> <<"506 Variant Also Negotiates">>;
status(507) -> <<"507 Insufficient Storage">>;
status(510) -> <<"510 Not Extended">>;
status(511) -> <<"511 Network Authentication Required">>;
status(I) when is_integer(I), I >= 100, I < 1000 -> <<(integer_to_binary(I))/binary, "Status">>;
status(B) when is_binary(B) -> B.
