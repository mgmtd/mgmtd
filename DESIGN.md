Internal design
---------------

The cfg application provides a schema driven tree database with long
lived session transactions for updating multiple entries atomically.



Schema
------

The Schema used is yang compatible opening the door to future use of
yang modules as a source of the schema.

Today the database schema is created by the managed system using the
APIs provided here.

The managed system must define a tree of nodes and leafs using the
functions in the cfg module:

* cfg:container/4 - create a container node with children

* cfg:list/4 - create a node to act as parent to a list of other trees or leafs

* cfg:leaf_list - create a node to hold a list of single typed values
                  e.g numbers or strings

* cfg:leaf - create a node to hole a single typed value

The managed system must then install the schema by calling
cfg:load_schema/1 with a list of functions that will create the
top level nodes of the tree.



Configuration transactions
==========================

Creating a transaction
----------------------

A configuration transaction is created typically when the user
switches to configuration mode in the CLI.

The new transaction creates a full copy of the configuration
database in a transaction local ets table. cfg_db:copy_to_ets() will
grab a copy of the database from whichever storage backend is used.

Setting a value
---------------

Setting a value at a path will update the ets copy of the database and
append a {set, Path, Value} item in a list that can be applied
to the master database on commit.

This design allows changes to other parts of the tree to be made by
other transactions while a transaction is ongoing. The alternative
would be to completely replace the master database on commit, wiping
out other changes (or more likely making configuration mode available
to a single user at a time (exclusive mode).

Setting a value also requires that each level in the path is checked
against the schema

List items
----------

List items appear in the database as multiple #cfg{} records of
node_type = list at the same level, with the list key in the path
stored as a tuple of potentially compound values that must also exist
as leafs in the database.

The list #cfg{} value field is a handy place to store the names of the
parameters that go into the key.

The leaf values that make up the list key must be set in the
database. This is examtly in line with the yang specifications.

Example set parameters during a transaction:

    [{set ["interface", {"eth0"}, "name"], "eth0"},
     {set ["interface", {"eth0"}, "speed"], "1GbE"}].

These two set parameters will result in the following database entries:

#cfg{node_type = container, path = ["interface"], name = "interface"}
#cfg{node_type = list, path = ["interface", {"eth0"}], value = ["name"]}
#cfg{node_type = leaf, path = ["interface", {"eth0"}, "name"], name = "name", value = "eth0"}
#cfg{node_type = leaf, path = ["interface", {"eth0"}, "speed"], name = "speed", value = "1GbE"}

The additional nodes will be created if they don't already exist

List items at the same level as other entries
---------------------------------------------

In the above example the "interface" container exists at the same level
as the list item. This opens the door to CLI elements like:

set interface <TAB>

Possible Completions:
  global - Global interface settings

Possible list items:
  eth0
  eth1

I'm not sure whether this is supported by Yang?

Multiple list items in the schema at the same level is prevented by
the schema loader

Namespaces
----------

In yang all nodes exist in an XML style namespace. This is supported,
but optional here. Any schema nodes without a namespace are put in a
global table with namespace set to the atom 'default'.

Database backends
-----------------

The system is designed to support different storage backends
The storage engine is configurable when calling cfg:init/2

Storage backends must provide set of functions to mirror the mnesia API:

init() - Called once at startup to allow the backend to create tables / init schema etc.

transaction(Fun) - Run a transaction against the DB where Fun will perform any updates

read(Key) - read entry at Key

write(#cfg{} = Record) - write Record to the config table

Fun can use cfg_db:read/1, cfg_db:write/1 which will be re-directed to
the backend specific functions.

Children
========

To look up the children at a path for display as a menu:

Children of a container at path "c1" - Simple list of node types from the schema

Children of a list item:
    - Special node 'add_new_entry' if we are adding a list item
    - unique list of the first key elements from the config
      or operational database.
    - The possible leafs of the list items if it's a show command (if we want
      to show all the list items for a single leaf) from the schema

Children of a list item after the first key when there are more keys:
    - Special node 'add_new_entry' for the next list key item
    - Unique list of the second key elements from the config
    - The possible nodes inside the list for a show command

Children of a list item after all keys:
    - Nodes inside the list from the schema

Children of a leaf for a set command (no children if it's a show command)
    - enum values if it's an enum
    - " if it's a string ??
    - <int> or similar prompt if it's another data type

Children of a leaf_list
    - [

Children of a leaf list opener
    - ]

set client clients key1 key2 port value

Subscriptions
=============

Processes can subscribe to receive notifications of changes to the
configuration.

A process can subscribe to changes using

    {ok, Ref} = cfg:subscribe(Path, Pid)

where Path is the path to the part of the tree of interest as a list
of path names e.g. ["server", "servers"], and Pid is the Pid of the
process that should be notified. List keys should be tuples
e.g. ["server", "servers", {"host1"}, "port"]

Configuration changes are delivered as a message {updated_config, Ref,
UpdatedConfig} where Ref is the reference returned by the call to
cfg:subscribe/2

UpdatedConfig depends on the type of node that is subscribed to:

List Node -> UpdatedConfig is the full list of items after all
             changes have been applied

Container -> UpdatedConfig is a list of leaf nodes immediately below
             the container with their values as Key Value pairs :
             [{LeafName1, NewValue1}, {LeafName2, NewValue2}]

Leaf -> UpdatedConfig is [{LeafName, NewValue}]

Q. Should we also provide the previous values?
Q. Should we exclude entries that have not changed or always provide the full config
Q. Maybe allow both options by configuration in the call to subscribe?

Q. Maybe we should provide the list of changes instead, so for list
   items do the diffing for the user: {added, [X,Y,Z]}, {deleted, [A,B]},
   or for leafs

Options

subtree - Instead of just immediate children, send updates if any part
          of the subtree changes and include the full subtree in the
          updated_config message.

include_unchanged - When providing KV list of values include all values in cluding those that were not changed during the transaction.

include_before - send {updated_config, Ref, Before, After} 

Implementation
--------------

We store an ets bag of all the subscriptions Path -> Pid. At commit time we
traverse the ets table looking up the value of each path in both the
txn ets copy and the backing store. Any items that are different
between new and old trigger an updated_config message.

This happens during commit. Order of events is a bit unclear..

Perhaps:

1. First run through changes to make sure they will apply to the database cleanly
2. Send out subscriptions
3. Write database transaction

This means we could have sent subscriptions but the actual database
write transaction could fail.

So maybe:

1. Generate all subscription messages based on pre-commit db and txn
   db, but don't send them.
2. Write database transaction.
3. Send pre-prepared subscription messages if db transaction succeeded.

With a lot of subscribed processes this could be a bit heavy, but
seems safest. Run with this option for now.

Next up
---

 - get enum values working for all schema types
 - get the rest of the yang datatypes working
 - add yang schema support
 - add namespace support
 - add sys.config style database where namespace maps to application name
 - add pipe commands