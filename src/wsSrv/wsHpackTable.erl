%%%-------------------------------------------------------------------
%%% @doc
%%% HPACK 静态表（RFC 7541 Appendix A）。
%%%
%%% 【自动生成，请勿手工修改】重新生成：
%%%     python3 tools/gen_static_table.py tools/rfc7541.txt \
%%%             src/wsCli/wsHpackTable.erl
%%%
%%%   get(Index)  -> {Name, Value}     %% 解码按索引取条目
%%%   full({N,V}) -> Index | none      %% 编码完全命中
%%%   name(Name)  -> Index | none      %% 编码仅名字命中（最小索引）
%%% BEAM 会对稠密整数键生成跳转表，对 binary 键生成哈希表。
%%% @end
%%%-------------------------------------------------------------------
-module(wsHpackTable).

-export([get/1, full/1, name/1]).

%%--------------------------------------------------------------------
%% get/1 — 按 HPACK 静态表索引（1..61）取条目
%%--------------------------------------------------------------------
get(1) -> {<<":authority">>, <<"">>};
get(2) -> {<<":method">>, <<"GET">>};
get(3) -> {<<":method">>, <<"POST">>};
get(4) -> {<<":path">>, <<"/">>};
get(5) -> {<<":path">>, <<"/index.html">>};
get(6) -> {<<":scheme">>, <<"http">>};
get(7) -> {<<":scheme">>, <<"https">>};
get(8) -> {<<":status">>, <<"200">>};
get(9) -> {<<":status">>, <<"204">>};
get(10) -> {<<":status">>, <<"206">>};
get(11) -> {<<":status">>, <<"304">>};
get(12) -> {<<":status">>, <<"400">>};
get(13) -> {<<":status">>, <<"404">>};
get(14) -> {<<":status">>, <<"500">>};
get(15) -> {<<"accept-charset">>, <<"">>};
get(16) -> {<<"accept-encoding">>, <<"gzip, deflate">>};
get(17) -> {<<"accept-language">>, <<"">>};
get(18) -> {<<"accept-ranges">>, <<"">>};
get(19) -> {<<"accept">>, <<"">>};
get(20) -> {<<"access-control-allow-origin">>, <<"">>};
get(21) -> {<<"age">>, <<"">>};
get(22) -> {<<"allow">>, <<"">>};
get(23) -> {<<"authorization">>, <<"">>};
get(24) -> {<<"cache-control">>, <<"">>};
get(25) -> {<<"content-disposition">>, <<"">>};
get(26) -> {<<"content-encoding">>, <<"">>};
get(27) -> {<<"content-language">>, <<"">>};
get(28) -> {<<"content-length">>, <<"">>};
get(29) -> {<<"content-location">>, <<"">>};
get(30) -> {<<"content-range">>, <<"">>};
get(31) -> {<<"content-type">>, <<"">>};
get(32) -> {<<"cookie">>, <<"">>};
get(33) -> {<<"date">>, <<"">>};
get(34) -> {<<"etag">>, <<"">>};
get(35) -> {<<"expect">>, <<"">>};
get(36) -> {<<"expires">>, <<"">>};
get(37) -> {<<"from">>, <<"">>};
get(38) -> {<<"host">>, <<"">>};
get(39) -> {<<"if-match">>, <<"">>};
get(40) -> {<<"if-modified-since">>, <<"">>};
get(41) -> {<<"if-none-match">>, <<"">>};
get(42) -> {<<"if-range">>, <<"">>};
get(43) -> {<<"if-unmodified-since">>, <<"">>};
get(44) -> {<<"last-modified">>, <<"">>};
get(45) -> {<<"link">>, <<"">>};
get(46) -> {<<"location">>, <<"">>};
get(47) -> {<<"max-forwards">>, <<"">>};
get(48) -> {<<"proxy-authenticate">>, <<"">>};
get(49) -> {<<"proxy-authorization">>, <<"">>};
get(50) -> {<<"range">>, <<"">>};
get(51) -> {<<"referer">>, <<"">>};
get(52) -> {<<"refresh">>, <<"">>};
get(53) -> {<<"retry-after">>, <<"">>};
get(54) -> {<<"server">>, <<"">>};
get(55) -> {<<"set-cookie">>, <<"">>};
get(56) -> {<<"strict-transport-security">>, <<"">>};
get(57) -> {<<"transfer-encoding">>, <<"">>};
get(58) -> {<<"user-agent">>, <<"">>};
get(59) -> {<<"vary">>, <<"">>};
get(60) -> {<<"via">>, <<"">>};
get(61) -> {<<"www-authenticate">>, <<"">>};
get(_) -> error.

%%--------------------------------------------------------------------
%% full/1 — 名+值完全命中（编码路径）
%%--------------------------------------------------------------------
full({<<":authority">>, <<"">>}) -> 1;
full({<<":method">>, <<"GET">>}) -> 2;
full({<<":method">>, <<"POST">>}) -> 3;
full({<<":path">>, <<"/">>}) -> 4;
full({<<":path">>, <<"/index.html">>}) -> 5;
full({<<":scheme">>, <<"http">>}) -> 6;
full({<<":scheme">>, <<"https">>}) -> 7;
full({<<":status">>, <<"200">>}) -> 8;
full({<<":status">>, <<"204">>}) -> 9;
full({<<":status">>, <<"206">>}) -> 10;
full({<<":status">>, <<"304">>}) -> 11;
full({<<":status">>, <<"400">>}) -> 12;
full({<<":status">>, <<"404">>}) -> 13;
full({<<":status">>, <<"500">>}) -> 14;
full({<<"accept-charset">>, <<"">>}) -> 15;
full({<<"accept-encoding">>, <<"gzip, deflate">>}) -> 16;
full({<<"accept-language">>, <<"">>}) -> 17;
full({<<"accept-ranges">>, <<"">>}) -> 18;
full({<<"accept">>, <<"">>}) -> 19;
full({<<"access-control-allow-origin">>, <<"">>}) -> 20;
full({<<"age">>, <<"">>}) -> 21;
full({<<"allow">>, <<"">>}) -> 22;
full({<<"authorization">>, <<"">>}) -> 23;
full({<<"cache-control">>, <<"">>}) -> 24;
full({<<"content-disposition">>, <<"">>}) -> 25;
full({<<"content-encoding">>, <<"">>}) -> 26;
full({<<"content-language">>, <<"">>}) -> 27;
full({<<"content-length">>, <<"">>}) -> 28;
full({<<"content-location">>, <<"">>}) -> 29;
full({<<"content-range">>, <<"">>}) -> 30;
full({<<"content-type">>, <<"">>}) -> 31;
full({<<"cookie">>, <<"">>}) -> 32;
full({<<"date">>, <<"">>}) -> 33;
full({<<"etag">>, <<"">>}) -> 34;
full({<<"expect">>, <<"">>}) -> 35;
full({<<"expires">>, <<"">>}) -> 36;
full({<<"from">>, <<"">>}) -> 37;
full({<<"host">>, <<"">>}) -> 38;
full({<<"if-match">>, <<"">>}) -> 39;
full({<<"if-modified-since">>, <<"">>}) -> 40;
full({<<"if-none-match">>, <<"">>}) -> 41;
full({<<"if-range">>, <<"">>}) -> 42;
full({<<"if-unmodified-since">>, <<"">>}) -> 43;
full({<<"last-modified">>, <<"">>}) -> 44;
full({<<"link">>, <<"">>}) -> 45;
full({<<"location">>, <<"">>}) -> 46;
full({<<"max-forwards">>, <<"">>}) -> 47;
full({<<"proxy-authenticate">>, <<"">>}) -> 48;
full({<<"proxy-authorization">>, <<"">>}) -> 49;
full({<<"range">>, <<"">>}) -> 50;
full({<<"referer">>, <<"">>}) -> 51;
full({<<"refresh">>, <<"">>}) -> 52;
full({<<"retry-after">>, <<"">>}) -> 53;
full({<<"server">>, <<"">>}) -> 54;
full({<<"set-cookie">>, <<"">>}) -> 55;
full({<<"strict-transport-security">>, <<"">>}) -> 56;
full({<<"transfer-encoding">>, <<"">>}) -> 57;
full({<<"user-agent">>, <<"">>}) -> 58;
full({<<"vary">>, <<"">>}) -> 59;
full({<<"via">>, <<"">>}) -> 60;
full({<<"www-authenticate">>, <<"">>}) -> 61;
full(_) -> none.

%%--------------------------------------------------------------------
%% name/1 — 仅名字命中；同名多项保留最小索引（与线性扫描一致）
%%--------------------------------------------------------------------
name(<<":authority">>) -> 1;
name(<<":method">>) -> 2;
name(<<":path">>) -> 4;
name(<<":scheme">>) -> 6;
name(<<":status">>) -> 8;
name(<<"accept-charset">>) -> 15;
name(<<"accept-encoding">>) -> 16;
name(<<"accept-language">>) -> 17;
name(<<"accept-ranges">>) -> 18;
name(<<"accept">>) -> 19;
name(<<"access-control-allow-origin">>) -> 20;
name(<<"age">>) -> 21;
name(<<"allow">>) -> 22;
name(<<"authorization">>) -> 23;
name(<<"cache-control">>) -> 24;
name(<<"content-disposition">>) -> 25;
name(<<"content-encoding">>) -> 26;
name(<<"content-language">>) -> 27;
name(<<"content-length">>) -> 28;
name(<<"content-location">>) -> 29;
name(<<"content-range">>) -> 30;
name(<<"content-type">>) -> 31;
name(<<"cookie">>) -> 32;
name(<<"date">>) -> 33;
name(<<"etag">>) -> 34;
name(<<"expect">>) -> 35;
name(<<"expires">>) -> 36;
name(<<"from">>) -> 37;
name(<<"host">>) -> 38;
name(<<"if-match">>) -> 39;
name(<<"if-modified-since">>) -> 40;
name(<<"if-none-match">>) -> 41;
name(<<"if-range">>) -> 42;
name(<<"if-unmodified-since">>) -> 43;
name(<<"last-modified">>) -> 44;
name(<<"link">>) -> 45;
name(<<"location">>) -> 46;
name(<<"max-forwards">>) -> 47;
name(<<"proxy-authenticate">>) -> 48;
name(<<"proxy-authorization">>) -> 49;
name(<<"range">>) -> 50;
name(<<"referer">>) -> 51;
name(<<"refresh">>) -> 52;
name(<<"retry-after">>) -> 53;
name(<<"server">>) -> 54;
name(<<"set-cookie">>) -> 55;
name(<<"strict-transport-security">>) -> 56;
name(<<"transfer-encoding">>) -> 57;
name(<<"user-agent">>) -> 58;
name(<<"vary">>) -> 59;
name(<<"via">>) -> 60;
name(<<"www-authenticate">>) -> 61;
name(_) -> none.
