# seshat fish integration

The standalone fish client has been retired. The Zig binary (`client/zig/`) is now the one
true client. This directory is reserved for thin fish *integration* — shell completions and a
prompt hook that shell out to the `seshat` binary — added in a later spec. There is no client
logic here anymore.
