-module(wsHttpProtocol).

-include("wsCom.hrl").

-compile(inline).
-compile({inline_size, 128}).

-export([request/4]).

-spec request(Stage :: stage(), Data :: binary(), wsSocket(), State :: #wsState{}) -> {ok, NewState :: #wsState{}} | {wsDone, NewState :: #wsState{}}  | {error, term()}.
request(reqLine, Data, Socket, State) ->
   case erlang:decode_packet(http_bin, Data, []) of
      {more, _} ->
         {ok, State#wsState{buffer = Data}};
      {ok, {http_request, Method, RawPath, Version}, Rest} ->
         case parsePath(RawPath) of
            {ok, Scheme, Host, Port, Path, URLArgs} ->
               case Rest of
                  <<>> ->
                     {ok, State#wsState{stage = wsHeader, buffer = <<>>, method = Method, path = Path, wsReq = #wsReq{method = Method, path = Path, version = Version, scheme = Scheme, host = Host, port = Port, socket = Socket, args = URLArgs}}};
                  _ ->
                     request(wsHeader, Rest, Socket, State#wsState{stage = wsHeader, buffer = Rest, method = Method, path = Path, wsReq = #wsReq{method = Method, path = Path, version = Version, scheme = Scheme, host = Host, port = Port, socket = Socket, args = URLArgs}})
               end;
            _Err ->
               _Err
         end;
      {ok, {http_error, ErrStr}, _} ->
         {error, ErrStr};
      {ok, {http_response, _, _, _}, _} ->
         {error, http_response};
      {error, _Reason} = Ret ->
         Ret
   end;
request(wsHeader, Data, Socket, State) ->
   parseHeaders(Data, Socket, State);

request(wsBody, Data, _Socket, State) ->
   #wsState{contentLength = CLen, wsReq = WsReq, temChunked = TemChunked, rn = Rn, maxSize = MaxSize} = State,
   case CLen of
      chunked ->
         case parseChunks(Data, Rn, TemChunked, MaxSize) of
            {ok, NewTemChunked, Rest} ->
               {ok, State#wsState{buffer = Rest, temChunked = NewTemChunked}};
            {over, LastTemChunked, Rest} ->
               {wsDone, State#wsState{buffer = Rest, temChunked = <<>>, wsReq = WsReq#wsReq{body = LastTemChunked}}};
            {err_code, _} = Ret ->
               Ret;
            {error, _Reason} = Ret ->
               Ret
         end;
      _ ->
         BodySize = byte_size(Data),
         if
            BodySize == CLen ->
               {wsDone, State#wsState{buffer = <<>>, wsReq = WsReq#wsReq{body = Data}}};
            BodySize > CLen ->
               <<Body:CLen/binary, Rest/binary>> = Data,
               {wsDone, State#wsState{buffer = Rest, wsReq = WsReq#wsReq{body = Body}}};
            true ->
               {ok, State#wsState{buffer = Data}}
         end
   end;
request(wsWs, Data, _Socket, State) ->
   {ok, Frames, RemainingBuffer} = wsWebSocket:parseWebSocketFrames(Data, State, []),
   wsWebSocket:processFrames(Frames, State#wsState{buffer = RemainingBuffer}).

parseHeaders(Data, Socket, State) ->
   case erlang:decode_packet(httph_bin, Data, []) of
      {more, _} ->
         {ok, State#wsState{buffer = Data}};
      {ok, {http_header, _, Key, _, Value}, Rest} ->
         #wsState{headerCnt = HeaderCnt, temHeader = TemHeader, rn = Rn, maxSize = MaxSize, chunkedSupp = ChunkedSupp, wsReq = WsReq} = State,
         NewTemHeader = [{Key, Value} | TemHeader],
         NewHeaderCnt = HeaderCnt + 1,
         case NewHeaderCnt >= 100 of
            true ->
               {error, too_many_headers};
            _ ->
               case Key of
                  'Content-Length' ->
                     ContentLength = binary_to_integer(Value),
                     case ContentLength > MaxSize of
                        true ->
                           {err_code, 413};
                        _ ->
                           parseHeaders(Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader, contentLength = ContentLength})
                     end;
                  'Transfer-Encoding' ->
                     IsChunked = ?CASE(Value == <<"chunked">> orelse Value == <<"Chunked">>, true, false),
                     case IsChunked of
                        true ->
                           case ChunkedSupp of
                              true ->
                                 case Rn of
                                    undefined ->
                                       parseHeaders(Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader, contentLength = chunked, rn = binary:compile_pattern(<<"\r\n">>)});
                                    _ ->
                                       parseHeaders(Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader, contentLength = chunked})
                                 end;
                              _ ->
                                 {error, not_support_chunked}
                           end;
                        _ ->
                           {error, 'Transfer-Encoding'}
                     end;
                  'Host' ->
                     % 只有当host字段为undefined时才使用Host头（HTTP/1.1协议规定）
                     case WsReq#wsReq.host of
                        undefined ->
                           % host字段为undefined，说明请求使用相对路径，需要使用Host头
                           case parseHostHeader(Value) of
                              {Host, Port} ->
                                 NewWsReq = WsReq#wsReq{host = Host, port = Port},
                                 parseHeaders(Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader, wsReq = NewWsReq});
                              _ ->
                                 parseHeaders(Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader})
                           end;
                        _ ->
                           % host字段已有值，说明请求使用绝对URI，忽略Host头（HTTP/1.1协议规定）
                           parseHeaders(Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader})
                     end;
                  _ ->
                     parseHeaders(Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader})
               end
         end;
      {ok, http_eoh, Rest} ->
         #wsState{temHeader = TemHeader, contentLength = CLen, wsReq = WsReq} = State,
         NewWsReq = WsReq#wsReq{headers = TemHeader},
         LCLen = case CLen of undefined -> 0; V -> V end,
         case LCLen of
            0 ->
               {wsDone, State#wsState{buffer = Rest, wsReq = NewWsReq}};
            _ ->
               case Rest of
                  <<>> ->
                     {ok, State#wsState{stage = wsBody, buffer = <<>>, wsReq = NewWsReq}};
                  _ ->
                     request(wsBody, Rest, Socket, State#wsState{stage = wsBody, buffer = Rest, wsReq = NewWsReq})
               end
         end;
      {ok, {http_error, ErrStr}, _Rest} ->
         {error, ErrStr};
      {error, _Reason} = Ret ->
         Ret
   end.

parseChunks(Data, Rn, Acc, MaxSize) ->
   case binary:split(Data, Rn) of
      [Size, Rest] ->
         case chunkSize(Size) of
            undefined ->
               {error, invalid_chunk_size};
            0 ->
               {over, Acc, Rest};
            HexSize ->
               %% Enforce accumulated size limit when using chunked transfer
               Exceed = ?CASE(MaxSize == infinity, false, byte_size(Acc) + HexSize > MaxSize),
               case Exceed of
                  true ->
                     {err_code, 413};
                  _ ->
                     case chunkBody(Rest, HexSize) of
                        not_enough_data ->
                           {ok, Acc, Data};
                        {ok, Body, NextRest} ->
                           parseChunks(NextRest, Rn, <<Acc/binary, Body/binary>>, MaxSize)
                     end
               end
         end
   end.

chunkBody(Data, Size) ->
   case Data of
      <<Body:Size/binary, "\r\n", Rest/binary>> ->
         {ok, Body, Rest};
      _ ->
         not_enough_data
   end.

chunkSize(Bin) ->
   try
      binary_to_integer(Bin, 16)
   catch
      error:badarg ->
         undefined
   end.

%% 解析Host头，格式为 "hostname" 或 "hostname:port"
parseHostHeader(HostHeader) when is_binary(HostHeader) ->
   case binary:split(HostHeader, <<":">>) of
      [Host] ->
         {Host, 80};  % 默认HTTP端口
      [Host, PortStr] ->
         try
            Port = binary_to_integer(PortStr),
            {Host, Port}
         catch
            _:_ ->
               {Host, 80}  % 端口解析失败，使用默认端口
         end;
      _ ->
         undefined
   end;
parseHostHeader(_) ->
   undefined.

parsePath({abs_path, FullPath}) ->
   URIMap = uri_string:parse(FullPath),
   Host = maps:get(host, URIMap, undefined),
   Scheme = maps:get(scheme, URIMap, undefined),
   Path = maps:get(path, URIMap, <<>>),
   Query = maps:get(query, URIMap, <<>>),
   Port = maps:get(port, URIMap, case Scheme of http -> 80; https -> 443; _ -> 0 end),
   {ok, Scheme, Host, Port, Path, uri_string:dissect_query(Query)};
parsePath({absoluteURI, Scheme, Host, Port, Path}) ->
   {_, _Scheme, _Host, _Port, RetPath, RetQuery} = parsePath({abs_path, Path}),
   {ok, Scheme, Host, Port, RetPath, RetQuery};
parsePath(_) ->
   {error, unsupported_uri}.