%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc Eunit tests for cfg_db
%%%
%%% @end
%%% Created : 25 Sep 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_tree_test).

-include("../src/mgmtd_schema.hrl").

-include_lib("eunit/include/eunit.hrl").

configs() ->
    [
     #cfg{path = ["a"], name = "a"},
     #cfg{path = ["a", "b"], name = "b"},
     #cfg{path = ["a", "b", "c"], name = "c", node_type = leaf, value = c_val},
     #cfg{path = ["a", "b", "d"], name = "d", node_type = leaf, value = d_val},
     #cfg{path = ["a", "e"], name = "e", node_type = leaf, value = e_val}
    ].

expected_tree() ->
    [#cfg{path = ["a"],
          name = "a",
          value =
              [#cfg{path = ["a", "b"],
                    name = "b",
                    value =
                        [#cfg{path = ["a", "b", "c"],
                              name = "c",
                              node_type = leaf,
                              value = c_val},
                         #cfg{path = ["a", "b", "d"],
                              name = "d",
                              node_type = leaf,
                              value = d_val}]},
               #cfg{path = ["a", "e"],
                    name = "e",
                    node_type = leaf,
                    value = e_val}]}].

cfg_db_to_tree_test_() ->
    Tree = mgmtd_cfg_db:cfg_list_to_tree(configs()),
    Expected = expected_tree(),
    ?_assertEqual(Expected, Tree).
