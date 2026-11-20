Status: needs-triage
Category: enhancement

# A call's tools cross to the owner and worker five times

## Parent

[Hold a call's tools once](../PRD.md)

## Problem

Observable: starting a call with `llm_wire.stream` (and so `run`) copies the
admitted tool list about five times, and the prepared request twice. With ten
`tool.new` tools of 783 words each, the values that cross are about 39,900
words per call (5.1 times the 7,830-word list) and about 700 words with no
tools. A tool from `tool.new` holds its input codec, so a larger codec
multiplies the cost five times. Contract-only tools hold no codec and copy
only schema data.

## Behavior to build

- The owner process receives the admitted tools once per call.
- The HTTP worker receives only the values it reads: the HTTP request, the
  limits it enforces and the stream handle. It receives no tool list and no
  conversation messages.
- The prepared request's messages cross to a new process at most once per
  call.
- Tool-call admission, retry evidence, streaming and cancellation behave as
  before.

## Interfaces

No public interface changes. The internal start of the owner and of the
transport worker change what they capture.

## Acceptance criteria

- A test on Erlang starts a call with ten `tool.new` tools and asserts that
  the flat size of the owner start closure environment and of the worker
  start closure environment together stays under 1.5 times the flat size of
  the tool list plus a fixed allowance for everything else (the no-tools
  value above, with headroom).
- The same test traces the sends of the calling process and of every process
  it spawns, through the start and a scripted answer, and sums the flat size
  of every message sent. The sum with ten tools may exceed the sum with no
  tools by at most half the flat size of the tool list, so a later change
  that sends the tools once more by message fails the test. (Measured today:
  the two sums are equal, 6,541 words each over the start, so no message
  carries the tools.)
- The same test with zero tools bounds the start environments under the
  fixed allowance.
- The full gate passes, including the H1, TLS and H2 harness cases.
- The README section "Codecs and process copies" and the `llm_wire/tool`
  module doc state the new per-call cost (one copy of the tool list into the
  owner, none into the worker) and drop the five-copy figures.

## Out of scope

- Changing what `tool.new` stores.
- Changing codec shapes in json_blueprint.

## Blocked by

None.

## Gate

```sh
nix develop -c sh dev/gate full
```

## Stop and ask

- If holding the tools once changes when an invalid tool call is admitted or
  reported, stop: that is a behavior change the design must accept first.
- If the worker needs a value that only the tool list or the messages hold,
  stop and ask which value to pass.

## Comments

AI-assisted contribution. Evidence, measured on json_blueprint 2.1.1 with
`erts_debug:flat_size` on the PR branch of
[gleam-dream/llm_wire#11](https://github.com/gleam-dream/llm_wire/pull/11),
using temporary instrumentation that was not committed.

Method: report the flat size of the values the owner start and the worker
start capture, and the post-start heap of the owner and worker against a
fake server that accepts and never answers.

| Value                                                                     | 0 tools | 10 tools (7,830 words) |
| ------------------------------------------------------------------------- | ------: | ---------------------: |
| tool list                                                                 |       0 |                  7,830 |
| prepared request                                                          |     147 |                  7,977 |
| owner setup, original                                                     |      63 |                  7,893 |
| owner setup, with reducer                                                 |     192 |                  8,022 |
| transport start closure                                                   |     254 |                 15,914 |
| owner start environment (setup, transport closure, budget)                |     453 |                 23,943 |
| worker start environment (client, prepared, budget, stream, setup, ready) |     272 |                 15,932 |

The owner start environment is 3.06 times the tool list and the worker start
environment 2.03 times: 5.1 times in all (39,875 words). The heap check
agrees: after start, before any collection, the owner and worker heaps held
17,731 and 20,323 words (38,054 words, 4.9 times the list) against 987 and
610 words with no tools. After a full collection the owner still held 17,121
words more than with no tools (2.2 times the list) and the worker 6,396 more
(0.8 times), so copies stay alive after start as well as crossing it.

The copies come from the owner's setup, the transport start function that
captures the prepared request and the original setup, and the worker, which
captures the prepared request and the setup again. The worker reads neither
the prepared request's tool list nor its messages.
