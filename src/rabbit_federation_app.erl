%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_federation_app).

-behaviour(application).
-export([start/2, stop/1]).

%% This does the same dummy supervisor thing as rabbit_mgmt_app - see the
%% comment there.
-behaviour(supervisor).
-export([init/1]).

-include_lib("amqp_client/include/amqp_client.hrl").

start(_Type, _StartArgs) ->
    {ok, Xs} = application:get_env(exchanges),
    [declare_exchange(X) || X <- Xs],
    rabbit_federation_link:go(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

stop(_State) ->
    ok.

%%----------------------------------------------------------------------------

declare_exchange(Props) ->
    {ok, DefaultVHost} = application:get_env(rabbit, default_vhost),
    VHost = list_to_binary(
              pget(virtual_host, Props, binary_to_list(DefaultVHost))),
    Params = rabbit_federation_util:local_params(),
    Params1 = Params#amqp_params_direct{virtual_host = VHost},
    {ok, Conn} = amqp_connection:start(Params1),
    {ok, Ch} = amqp_connection:open_channel(Conn),
    XName = list_to_binary(pget(exchange, Props)),
    amqp_channel:call(
      Ch, #'exchange.declare'{
        exchange    = XName,
        type        = <<"x-federation">>,
        durable     = pget(durable,     Props, true),
        auto_delete = pget(auto_delete, Props, false),
        internal    = pget(internal,    Props, false),
        arguments   =
            [{<<"upstreams">>, array,  [to_table(U, XName, VHost) ||
                                           U <- pget(upstreams, Props)]},
             {<<"type">>,      longstr, list_to_binary(pget(type, Props))}]}),
    amqp_channel:close(Ch),
    amqp_connection:close(Conn),
    ok.

to_table(Props, DefaultXName, DefaultVHost) ->
    rabbit_federation_upstream:to_table(
      rabbit_federation_upstream:from_props(Props, DefaultXName, DefaultVHost)).

pget(K, P, D) ->
    proplists:get_value(K, P, D).

pget(K, P) ->
    case proplists:get_value(K, P) of
        undefined -> exit({error, key_missing, K});
        V         -> V
    end.

%%----------------------------------------------------------------------------

init([]) -> {ok, {{one_for_one, 3, 10}, []}}.
