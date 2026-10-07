-module(wsBinarySearch).

-on_load(init/0).

-export([match/2]).

%% Fixed HTTP delimiters are shared by all connections. Compile them once when
%% this module is loaded instead of rebuilding the search pattern per request.
init() ->
	Patterns = [
		{'$wsBSCrlf', <<"\r\n">>},
		{'$wsBSHeaderEnd', <<"\r\n\r\n">>},
		{'$wsBSSemicolon', <<";">>},
		{'$wsBSCloseBracket', <<"]">>},
		{'$wsBSColon', <<":">>},
		{'$wsBSPathMarker', [<<"#">>, <<"?">>]},
		{'$wsBSFragment', <<"#">>},
		{'$wsBSQuery', <<"?">>},
		{'$wsBSMultipartFormData', <<"multipart/form-data">>}
	],
	[persistent_term:put(Name, binary:compile_pattern(Pattern)) || {Name, Pattern} <- Patterns],
	ok.

-type pattern_name() :: '$wsBSCrlf' | '$wsBSHeaderEnd' | '$wsBSSemicolon' | '$wsBSCloseBracket' | '$wsBSColon' | '$wsBSPathMarker' | '$wsBSFragment' | '$wsBSQuery' | '$wsBSMultipartFormData'.

-spec match(binary(), pattern_name()) -> {non_neg_integer(), pos_integer()} | nomatch.
match(Bin, Name) ->
	binary:match(Bin, persistent_term:get(Name)).
