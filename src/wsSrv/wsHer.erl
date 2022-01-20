-module(wsHer).

-include("eWSrv.hrl").

-export_type([
   response/0
]).

-type response() ::
   {wsHttpCode() | ok, wsBody()}|
   {wsHttpCode() | ok, wsHeaders(), wsBody()}|
   {wsHttpCode() | ok, wsHeaders(), {file, file:name_all()}|
   {file, file:name_all(), wsUtil:range()}}|
   {chunk, wsHeaders()}|
   {chunk, wsHeaders(), wsBody()}.

-callback handle(Method :: wsMethod(), Path :: binary(), Req :: wsReq()) -> response().