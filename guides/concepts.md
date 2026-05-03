# Concepts

Reach translates source code into an intermediate representation, builds control/data/call relationships, and combines them into a program dependence graph.

## Control flow

Control-flow graphs show branch structure inside functions. Reach keeps function CFGs acyclic and uses block-quality checks to ensure rendered blocks cover source lines without duplicates.

## Call graph

The call graph connects caller and callee functions. Reach uses it for dependency trees, impact analysis, module coupling, hotspots, and why-path explanations.

## Data flow

Data-flow edges track definitions, uses, parameters, returns, and cross-function value movement. Trace commands use these edges for taint and variable workflows.

## Effects

Reach classifies calls into effect categories such as pure, IO, read, write, send, receive, exception, NIF, and unknown. Effect evidence powers boundaries, smells, and refactoring candidates.

## OTP analysis

OTP checks identify GenServer state access, GenStatem transitions, missing handlers, dead replies, supervision, process dictionary/ETS coupling, and cross-process resource sharing.
