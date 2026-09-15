mgmtd
=====

**mgmtd** is a schema-driven configuration data store and operational data handler for Erlang. It should also work well in Elixir and Gleam systems.

It can be used standalone, or combined with the ecli library to add a local Juniper style cli

Features
===

- Schema driven configuration database
- Configuration and operational data driven by json schema, Yang, or Erlang data structures. Schemas can be combined from different sources.
- Almost full coverage of yang 1.1, including container, list (including user ordered), leaf and leaf-list, leafref, must.
- Configuration data store in mnesia, json file, or in a sys.config style file.
- Callback based interface to host erlang system to retrieve operational data
- Erlang API to subscribe and receive configuration changes from all or part of the config tree
- Transaction based configuration changes - multiple items can be changed in a single session followed by atomic commit
- Override configuration items with environment variables at startup ????
- Startup configuration in an empty system can be supplied in a file. Startup file remains unchanged.
- Safe concurrent user sessions, with conflicts reported to the last user to commit
- Transformation phase for sys.config backend to convert pure tree structure to and from differently structured sys.config e.g. for kernel logger config
- sys.config backend round trips parts of the file that are not covered by any configuration schema
- Previous configuration store with rollback. Configurable number of rollback copies
- erlydtl templates to host within an existing cowboy or other based UI
- RESTCONF API for remote query and update

Getting Started
===

Install from git (hex, and official releases coming)

{deps, [
        {mgmtd, {git, "https://github.com/mgmtd/mgmtd.git", {branch, "master"}}}
]}.

During your application startup first load your schemas:

```erlang
mgmtd:load_function_schema(fun() -> example:cfg_schema() end),
mgmtd:load_json_schema("apps/example/priv/example_schema.json"),
mgmtd:load_yang_schema("apps/example/priv/example_schema.yang").
```

Then start the configuration database specifying the directory where the DB should be created, and storage backend (mnesia | json | sys_config):

```erlang
mgmtd_cfg_db:init("db", [{backend, mnesia}]).
```

Most of the functionality is used by the example application at https://github.com/mgmtd/example.git. Until more documentation is available this example should get you started.


Build
-----

    $ rebar3 compile

Namespaces
----------

Each loaded schema has a **prefix** (an atom). JSON and Erlang schemas use `#{namespace => Prefix}` at load time. If omitted the prefix is `default`. YANG modules have a mandatory prefix which is used.

Schemas with the `default` prefix appear at the top level in the CLI. Named prefixes appear as the first path element

    set server servers foo port 8080
    set example server servers foo port 8080

The sys.config backend uses `{Prefix, Tree}` as the application name grouping, and (`{default, Tree}` for the default prefix).  

The JSON file backend (`{backend, json}`) writes a nested JSON tree to `config.json`. Named prefixes become root objects. The default prefix's children sit at the top level.

TODO
---

- [ ] AAA. Today there is no authentication for cli or RESTCONF
- [ ] Some kind of external API so programs outside of the host erlang system can read and subscribe to config
- [ ] Automatic / programmable database migration during startup after a schema change 
- [ ] Restriction to prevent new schemas being loaded after startup
- [ ] Yang rpc and action, hooked into RESTCONF
- [ ] XML based RESTCONF. Today it's only JSON

Why
---

This library has been a long time in the making. Having left behind multiple instances of this kind of functionality in closed source companies it felt like it was time to build one for the community.

The first iteration of this library was complete enough to get a sketch down, but never found a user (that I'm aware of). The companion ecli library did find uses in a few projects.

Energy and time were lacking for many years, but a potential use case, and the advent of our handy AI programming buddies solved the time and energy side.

It is my hope that other people find this useful. Feature requests and contributions welcome.