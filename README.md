mgmtd
=====

A self contained system for management of configuration and operational data in an Erlang program

It can be used standalone, or combined with ecli to allow cli menu access

Features (ok, wish list)
- Configuration and operational data driven by either json schema or Yang
- Embedded schema driven configuration database
- Option to provide external database interface
- Callback based interface to host system to retrieve operational data
- Subscription interface to recieve configuration changes
- Transaction based configuration changes - multiple items changed, then commit
- Override configuration items with environment variables at startup
- Automatic / programmable schema upgrades

Configuration
===

mgmtd itself can be configured in a number of ways. This config can be provided
in sys.config, via environment variables, or dynamically.

Available items:

- Configuration database directory
- Env variable override prefix


Components
===



mgmtd_schema
===========

Takes both JSON schema and Yang files in any combination and provides
a common api to query the schema and validate data against the schema.

The data model is based on Yang. JSON schema is squeezed into Yang
concepts where there is a conflict.

Build
-----

    $ rebar3 compile

Namespaces
----------

Each loaded schema has a **prefix** (an atom). JSON and Erlang schemas
use `#{namespace => Prefix}` at load time; if omitted the prefix is
`default`. YANG will also keep a namespace URI; the prefix is still
the CLI / `sys.config` name.

    mgmtd:load_function_schema(Fun).                       % prefix default
    mgmtd:load_function_schema(Fun, #{namespace => example}).
    mgmtd:load_json_schema(File, #{namespace => aeternity}).

Default prefix is omitted in the CLI. Named prefixes are a path token:

    set server servers foo port 8080
    set example server servers foo port 8080

A later sys.config backend will use `{Prefix, Tree}` as the
application-name grouping.

TODO
---

- [x] Fix completion of existing list keys
- [x] Finish enum support