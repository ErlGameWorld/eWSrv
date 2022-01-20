-module(wsUtil).

-include("wsCom.hrl").

-include_lib("kernel/include/file.hrl").

-export([
   gLV/3
   , mergeOpts/2
   , normalizeRange/2
   , encodeRange/2
   , fileSize/1
   , sendfile/5
]).

-export_type([range/0]).


gLV(Key, List, Default) ->
   case lists:keyfind(Key, 1, List) of
      false ->
         Default;
      {Key, Value} ->
         Value
   end.

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
normalizeRange({Offset, Length}, Size) when is_integer(Offset), is_integer(Length),
   Offset >= 0, Length >= 0, Offset < Size ->
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
         16#1FFF;
      false ->
         16#1FFF
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
