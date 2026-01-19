eWSrv
=====
otp22+
An erlang's http1.1 server 支持websocket

Build
-----

    $ rebar3 compile

## Usage

```sh
$ rebar3 shell
```

```erlang
%% starting
1 > eWSrv:openSrv(8888, []).
start with escriptize
eWSrv 8888 &

```

## Examples

    Examples handle module see wsTPHer.erl
    eWSrv:openSrv(8080, []).
    http://localhost:8080(完整测试)

