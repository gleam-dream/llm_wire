Status: ready-for-human
Category: enhancement

# Hold a call's tools once

## Problem

Starting one call copies the admitted tool list about five times: three times
into the owner process and twice into its HTTP worker. The prepared request,
which holds the conversation messages, is copied twice. A tool from
`tool.new` carries a decode function that holds its input codec, so each copy
includes the codec. The worker never reads the tool list, and the owner needs
it once, to admit returned tool calls. The cost is paid on every call and
grows with the number of tools and the size of their codecs (ten 783-word
tools: about 39,900 words per call, 5.1 times the list).

## User stories

- As an application that passes `tool.new` tools to direct calls, I want a
  call's memory cost to be one copy of my tools, so that a larger tool set or
  conversation does not multiply per call.
- As a maintainer, I want a test that bounds what a call copies, so that a
  later change cannot reintroduce the multiplication.

## Decisions

- The owner holds the admitted tools once per call; the worker holds only
  what it reads to send the request and read the response.
- No public API changes. The documented advice (small `tool.new` codecs,
  contract-only tools for run-time schemas) stays.

## Testing decisions

- Bound the flat size of what the owner start and the worker start capture,
  with a large `tool.new` tool, in a test on Erlang.
- Keep the existing H1, TLS and H2 gate cases unchanged.

## Out of scope

- Reworking `tool.new` so a tool no longer holds its codec.
- Changing the json_blueprint codec shapes, which the json_blueprint guide
  covers.

## Slices

- [01 A call's tools cross to the owner and worker five times](issues/01-tools-copied-five-times-per-call.md)
