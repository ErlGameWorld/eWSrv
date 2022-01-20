-module(wsHttpProtocol).

-include("wsCom.hrl").

-compile(inline).
-compile({inline_size, 128}).

-export([request/4]).

-spec request(Stage :: stage(), Data :: binary(), wsSocket(), State :: #wsState{}) -> {ok, NewState :: #wsState{}} | {done, NewState :: #wsState{}}  | {error, term()}.
request(reqLine, Data, Socket, State) ->
   case erlang:decode_packet(http_bin, Data, []) of
      {more, _} ->
         {ok, State#wsState{buffer = Data}};
      {ok, {http_request, Method, RawPath, Version}, Rest} ->
         case parsePath(RawPath) of
            {ok, Scheme, Host, Port, Path, URLArgs} ->
               case Rest of
                  <<>> ->
                     {ok, State#wsState{stage = header, buffer = <<>>, method = Method, path = Path, socket = Socket, wsReq = #wsReq{method = Method, path = Path, version = Version, scheme = Scheme, host = Host, port = Port, args = URLArgs}}};
                  _ ->
                     request(header, Rest, Socket, State#wsState{stage = header, buffer = Rest, method = Method, path = Path, wsReq = #wsReq{method = Method, path = Path, version = Version, scheme = Scheme, host = Host, port = Port, args = URLArgs}})
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
request(header, Data, Socket, State) ->
   case erlang:decode_packet(httph_bin, Data, []) of
      {more, _} ->
         {ok, State#wsState{buffer = Data}};
      {ok, {http_header, _, Key, _, Value}, Rest} ->
         #wsState{headerCnt = HeaderCnt, temHeader = TemHeader, rn = Rn, maxSize = MaxSize, chunkedSupp = ChunkedSupp} = State,
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
                           request(header, Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader, contentLength = ContentLength})
                     end;
                  'Transfer-Encoding' ->
                     IsChunked = ?IIF(Value == <<"chunked">> orelse Value == <<"Chunked">>, true, false),
                     case IsChunked of
                        true ->
                           case ChunkedSupp of
                              true ->
                                 case Rn of
                                    undefined ->
                                       request(header, Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader, contentLength = chunked, rn = binary:compile_pattern(<<"\r\n">>)});
                                    _ ->
                                       request(header, Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader, contentLength = chunked})
                                 end;
                              _ ->
                                 {error, not_support_chunked}
                           end;
                        _ ->
                           {error, 'Transfer-Encoding'}
                     end;
                  _ ->
                     request(header, Rest, Socket, State#wsState{buffer = Rest, headerCnt = NewHeaderCnt, temHeader = NewTemHeader})
               end
         end;
      {ok, http_eoh, Rest} ->
         #wsState{temHeader = TemHeader, contentLength = CLen, wsReq = WsReq} = State,
         NewWsReq = WsReq#wsReq{headers = TemHeader},
         case CLen of
            undefined ->
               {error, content_length};
            0 ->
               {done, State#wsState{buffer = Rest, wsReq = NewWsReq}};
            _ ->
               case Rest of
                  <<>> ->
                     {ok, State#wsState{stage = body, buffer = <<>>, wsReq = NewWsReq}};
                  _ ->
                     request(body, Rest, Socket, State#wsState{stage = body, buffer = Rest, wsReq = NewWsReq})
               end
         end;
      {ok, {http_error, ErrStr}, _Rest} ->
         {error, ErrStr};
      {error, _Reason} = Ret ->
         Ret
   end;
request(body, Data, _Socket, State) ->
   #wsState{contentLength = CLen, wsReq = WsReq, temChunked = TemChunked, rn = Rn} = State,
   case CLen of
      chunked ->
         case parseChunks(Data, Rn, TemChunked) of
            {ok, NewTemChunked, Rest} ->
               {ok, State#wsState{buffer = Rest, temChunked = NewTemChunked}};
            {over, LastTemChunked, Rest} ->
               {done, State#wsState{buffer = Rest, temChunked = <<>>, wsReq = WsReq#wsReq{body = LastTemChunked}}};
            {error, _Reason} = Ret ->
               Ret
         end;
      _ ->
         BodySize = byte_size(Data),
         if
            BodySize == CLen ->
               {done, State#wsState{buffer = <<>>, wsReq = WsReq#wsReq{body = Data}}};
            BodySize > CLen ->
               <<Body:CLen/binary, Rest/binary>> = Data,
               {done, State#wsState{buffer = Rest, wsReq = WsReq#wsReq{body = Body}}};
            true ->
               {ok, State#wsState{buffer = Data}}
         end
   end.

parseChunks(Data, Rn, Acc) ->
   case binary:split(Data, Rn) of
      [Size, Rest] ->
         case chunkSize(Size) of
            undefined ->
               {error, invalid_chunk_size};
            0 ->
               {over, Acc, Rest};
            HexSize ->
               case chunkBody(Rest, HexSize) of
                  not_enough_data ->
                     {ok, Acc, Data};
                  {ok, Body, Rest} ->
                     parseChunks(Rest, Rn, <<Acc/binary, Body/binary>>)
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