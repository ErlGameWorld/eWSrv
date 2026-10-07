-module(wsWsProtocolTestHandler).

-export([supportedProtocols/0]).

supportedProtocols() ->
   [<<"chat">>, <<"superchat">>].
