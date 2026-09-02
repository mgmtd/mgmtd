%%%-------------------------------------------------------------------
%%% @doc Behaviour for a subtree persistence codec.
%%%
%%% A codec is a term adapter at one schema node. The sys.config backend
%%% still walks the tree as proplists; when a node names `{codec, Mod}` in
%%% `opts`, that node's value is rewritten:
%%%
%%%   export(DefaultValue) -> WireValue
%%%   import(WireValue)    -> DefaultValue
%%%
%%% `DefaultValue` is the backend's native encoding (containers as
%%% proplists, lists as lists of proplists, leaf values as stored in
%%% `#cfg{}`). `WireValue` is what is written to / read from the file.
%%%
%%% Codecs do not nest: a codec owns the whole value at its node.
%%% Import throws `{import_error, Reason}` on failure; export throws
%%% `{export_error, Reason}`.
%%%
%%% Application-specific codecs (OTP logger, …) live with the host schema,
%%% not in this library. See `mgmtd_test_codec` for the in-tree test adapter.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_codec).

-callback export(DefaultValue :: term()) -> WireValue :: term().
-callback import(WireValue :: term()) -> DefaultValue :: term().
