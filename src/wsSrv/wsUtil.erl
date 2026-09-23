-module(wsUtil).

-include("wsCom.hrl").

-include_lib("kernel/include/file.hrl").

-export([
   gLV/3
   , getHeader/3
   , mergeOpts/2
   , normalizeRange/2
   , encodeRange/2
   , fileSize/1
   , sendfile/5
   , toLowerStr/1
   , ensureLower/1
   , isLowerAscii/1
   , headerNameEq/2
   , noCtlChars/1
]).

-export_type([range/0]).


gLV(Key, List, Default) ->
   case lists:keyfind(Key, 1, List) of
      false ->
         Default;
      {Key, Value} ->
         Value
   end.

getHeader(HeaderName, Headers, Default) ->
   case lists:keyfind(HeaderName, 1, Headers) of
      {HeaderName, Value} -> Value;
      false -> Default
   end.

toLowerStr(BinStr) when is_binary(BinStr) ->
   <<
      begin
         case C >= $A andalso C =< $Z of
            true ->
               <<(C + 32)>>;
            _ ->
               <<C>>
         end
      end || <<C:8>> <= BinStr
   >>;
toLowerStr(ListStr) when is_list(ListStr) ->
   [
      begin
         case C >= $A andalso C =< $Z of
            true ->
               C + 32;
            _ ->
               C
         end
      end || C <- ListStr
   ].

%% 已是小写的 binary 原样返回（零分配）；否则才走 toLowerStr。
ensureLower(Bin) when is_binary(Bin) ->
   case isLowerAscii(Bin) of
      true -> Bin;
      false -> toLowerStr(Bin)
   end.

%% 是否全为非大写 ASCII（用于 H2 强制小写头名检查，替代 Name =:= toLowerStr(Name)）。
isLowerAscii(<<>>) ->
   true;
isLowerAscii(<<C, _/binary>>) when C >= $A, C =< $Z ->
   false;
isLowerAscii(<<_, Rest/binary>>) ->
   isLowerAscii(Rest).

%% 大小写不敏感的 header 名比较，零分配：长度不等立即返回，
%% 否则逐字节比较并就地折叠大小写。
headerNameEq(A0, B0) ->
   A = toBin(A0),
   B = toBin(B0),
   byte_size(A) =:= byte_size(B) andalso headerNameEq_(A, B).

headerNameEq_(<<>>, <<>>) ->
   true;
headerNameEq_(<<A, RA/binary>>, <<B, RB/binary>>) ->
   downcaseChar(A) =:= downcaseChar(B) andalso headerNameEq_(RA, RB).

downcaseChar(C) when C >= $A, C =< $Z -> C + 32;
downcaseChar(C) -> C.

toBin(V) when is_binary(V) -> V;
toBin(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBin(V) when is_integer(V) -> integer_to_binary(V);
toBin(V) when is_list(V) -> iolist_to_binary(V).

%% RFC field-value 不允许 ASCII 控制字符；HTAB(0x09) 是唯一允许的 C0 例外。
%% H2 另外在调用侧禁止首尾 SP/HTAB。保持单遍扫描，不增加正常热路径遍历。
noCtlChars(<<>>) ->
   true;
noCtlChars(<<C, _/binary>>) when C < 32, C =/= 9 ->
   false;
noCtlChars(<<127, _/binary>>) ->
   false;
noCtlChars(<<_, Rest/binary>>) ->
   noCtlChars(Rest).

-spec mergeOpts(Defaults :: list(), Options :: list()) -> list().
mergeOpts(Defaults, Options) ->
   lists:foldl(
      fun({Opt, Val}, Acc) ->
         lists:keystore(Opt, 1, Acc, {Opt, Val});
         (Opt, Acc) ->
            lists:usort([Opt | Acc])
      end,
      Defaults, Options).

-type range() :: {Offset :: non_neg_integer(), Length :: non_neg_integer()}.
-spec normalizeRange(RangeOrSet, Size) -> Normalized when
   RangeOrSet :: any(),
   Size :: integer(),
   Normalized :: range() | undefined | invalid_range.
%% @doc: If a valid byte-range, or byte-range-set of size 1
%% is supplied, returns a normalized range in the format
%% {Offset, Length}. Returns undefined when an empty byte-range-set
%% is supplied and the atom `invalid_range' in all other cases.
normalizeRange({suffix, Length}, Size) when is_integer(Length), Length > 0 ->
   Length0 = erlang:min(Length, Size),
   {Size - Length0, Length0};
normalizeRange({offset, Offset}, Size) when is_integer(Offset), Offset >= 0, Offset < Size ->
   {Offset, Size - Offset};
normalizeRange({bytes, First, Last}, Size) when is_integer(First), is_integer(Last), First =< Last ->
   normalizeRange({First, Last - First + 1}, Size);
%% {0,0} 与 [] 一样表示整文件；否则 sendfile(Bytes=0) 会把整文件发出去，
%% 却配上 Content-Length: 0，keep-alive 上响应会脱同步。与 wsHttp2:fileSpan/2 对齐。
normalizeRange({0, 0}, _Size) ->
   undefined;
normalizeRange({Offset, Length}, Size) when is_integer(Offset), is_integer(Length),
   Offset >= 0, Length > 0, Offset < Size ->
   Length0 = erlang:min(Length, Size - Offset),
   {Offset, Length0};
normalizeRange([ByteRange], Size) ->
   normalizeRange(ByteRange, Size);
normalizeRange([], _Size) -> undefined;
normalizeRange(_, _Size) -> invalid_range.


-spec encodeRange(Range :: range() | invalid_range, Size :: non_neg_integer()) -> ByteRange :: iolist().
%% @doc: Encode Range to a Content-Range value.
encodeRange(Range, Size) ->
   [<<"bytes ">>, encodeRangeBytes(Range), <<"/">>, integer_to_binary(Size)].

encodeRangeBytes({Offset, Length}) ->
   [integer_to_binary(Offset), <<"-">>, integer_to_binary(Offset + Length - 1)];
encodeRangeBytes(invalid_range) -> <<"*">>.


-spec fileSize(Filename :: file:name_all()) -> Size :: non_neg_integer() | {error, Reason :: file:posix() | badarg | invalid_file}.
%% @doc: Get the size in bytes of the file.
fileSize(Filename) ->
   case file:read_file_info(Filename) of
      {ok, #file_info{type = regular, access = Perm, size = Size}} when Perm =:= read orelse Perm =:= read_write ->
         Size;
      {error, Reason} -> {error, Reason};
      _ -> {error, invalid_file}
   end.

%% @doc Send part of a file on a socket.
%%
%% Basically, @see file:sendfile/5 but for ssl (i.e. not raw OS sockets).
%% Originally from https://github.com/ninenines/ranch/pull/41/files
%%
%% @end
-spec sendfile(file:fd(), inet:socket() | ssl:sslsocket(), non_neg_integer(), non_neg_integer(), sendfile_opts()) -> {ok, non_neg_integer()} | {error, atom()}.
sendfile(RawFile, Socket, Offset, Bytes, Opts) ->
   ChunkSize = chunkSize(Opts),
   Initial2 =
      case file:position(RawFile, {cur, 0}) of
         {ok, Offset} ->
            Offset;
         {ok, Initial} ->
            {ok, _} = file:position(RawFile, {bof, Offset}),
            Initial
      end,
   case sendfileLoop(Socket, RawFile, Bytes, 0, ChunkSize) of
      {ok, _Sent} = Result ->
         {ok, _} = file:position(RawFile, {bof, Initial2}),
         Result;
      {error, _Reason} = Error ->
         Error
   end.

-spec chunkSize(sendfile_opts()) -> pos_integer().
chunkSize(Opts) ->
   case lists:keyfind(chunk_size, 1, Opts) of
      {chunk_size, ChunkSize}
         when is_integer(ChunkSize) andalso ChunkSize > 0 ->
         ChunkSize;
      {chunk_size, 0} ->
         64 * 1024;
      false ->
         64 * 1024
   end.

-spec sendfileLoop(inet:socket() | ssl:sslsocket(), file:fd(), non_neg_integer(), non_neg_integer(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
sendfileLoop(_Socket, _RawFile, Sent, Sent, _ChunkSize) when Sent =/= 0 ->
   %% All requested data has been read and sent, return number of bytes sent.
   {ok, Sent};
sendfileLoop(Socket, RawFile, Bytes, Sent, ChunkSize) ->
   ReadSize = read_size(Bytes, Sent, ChunkSize),
   case file:read(RawFile, ReadSize) of
      {ok, IoData} ->
         case ssl:send(Socket, IoData) of
            ok ->
               Sent2 = iolist_size(IoData) + Sent,
               sendfileLoop(Socket, RawFile, Bytes, Sent2, ChunkSize);
            {error, _Reason} = Error ->
               Error
         end;
      eof ->
         {ok, Sent};
      {error, _Reason} = Error ->
         Error
   end.

-spec read_size(non_neg_integer(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
read_size(0, _Sent, ChunkSize) ->
   ChunkSize;
read_size(Bytes, Sent, ChunkSize) ->
   min(Bytes - Sent, ChunkSize).
