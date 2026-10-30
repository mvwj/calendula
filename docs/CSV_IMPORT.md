# Schedule import

SIS CSV parsing supports UTF-8/BOM and labelled Windows-1250 input, quoted comma
or semicolon separators, multiline fields and escaped quotes. Source course and
meeting identities remain distinct. Invalid rows fail review with a row number.

An import rule retains title, teachers, exact time/duration and room. Generic
tables can also provide explicit address, venue, floor and class-type fields.
Missing metadata is not inferred from a course title. A bounded public MFF room
directory can resolve known rooms; other buildings require explicit confirmation.

Recurring teaching weeks require a confirmed Monday for week one and an import
window. The exporter may omit faculty holidays, cancellations or semester mapping.
Review dates and overlaps; do not claim a whole-semester mapping from a guessed
first day. Dates are expanded in Europe/Prague with DST validation.

Stable source/meeting/date identities prevent reimport from duplicating unchanged
occurrences. Exact-series place/type confirmation can be reused on later imports
when unambiguous; explicit new source values take precedence. Wider update and
exception semantics remain on the roadmap.

Permanent fixtures are synthetic. Optional local CSV checks use
`CALENDULA_TEST_CSV`; that file must remain outside Git. Never upload a real
schedule to a public issue to reproduce a parser problem.
