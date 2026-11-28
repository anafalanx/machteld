# X compiler optimization

Machteld compiles X to Tcl. The compiler uses the types established by the X checker to generate ordinary Tcl expressions, collection updates and calls. The runtime supplies native helpers for operations with a measured cost on complete applications. Generated applications can use portable implementations of optional compiler helpers on older hosts.

## Changes included in 0.51

- Branch conditions compile to braced Tcl expressions. Calls between X functions reuse type information that the compiler has already established. Calls from Tcl and results returned by a declared external function retain their boundary checks.
- Generated code specializes operations on known integer, boolean, text, list and record types. It can update a uniquely held list or dictionary directly and release an ignored result before the next operation or before a scoped resource is closed.
- Record and collection checks reuse compatible typed values. Integer-list validation has a dedicated native path and the compiler specializes lists of integer rows. Shared Tcl values, foreign inputs and optional fields retain their validation behavior.
- Checked floating-point operations preserve intermediate rounding, nonfinite-value errors and numeric representation across Tcl calls. Other changes improve exact decimal handling, typed SQLite reads, JSON number rendering and the export of retained values.
- Typed application code can keep a validated snapshot across multiple queries or event handlers within its declared scope. Archive checks exercise generated code on different runtime versions and preserve the results and errors visible to Tcl callers.

## Measuring a change

The [compiler workload corpus](../../test/corpus/compiler/README.md) compares X with independent handwritten Tcl. It covers integer recursion and GCD, floating-point grids, sorted collection operations, counts, exact decimal arithmetic, JSON decoding and SQL-backed reports. The [history workload](../../test/corpus/compiler/history.md) exercises imports, historical cutoffs and repeated queries on a common snapshot.

1. Check the complete output against an independently written reference before collecting timings. Include empty, duplicate, malformed and boundary inputs. For integration changes, check error codes, source locations, cleanup after failure and inputs created by earlier versions.
2. Measure both the code affected by the change and a complete application operation. Include argument validation, data conversion, SQL work and result construction when the normal caller pays those costs. Record application startup and authoring operations separately.
3. Use the same inputs, compare the same validation contracts, and alternate the implementations on the same machine. Report actual times or ratios to ordinary Tcl alongside the before-and-after comparison. A benchmark describes its own input size, distribution and runtime version.
4. Test emitted code with the embedded compiler and a relocated application archive. Exercise the portable path for any optional native compiler helper. A native operation that an application calls explicitly should document its minimum runtime version.

## Further work

Profile collection construction, retained values and boundary validation on real applications before extending the compiler. Repeated scans may move into a bulk operation or a prepared SQL query. A general interval operation, for example, can accept a flat list of integer endpoints from SQLite and return a flat list that subsequent X code can reuse. Application policy stays in X. Compare each proposed path with a portable implementation using the same input and output representations.
