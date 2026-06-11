# Group selection hardening

Roborev found that group selection could report success without safely saving
the selected group key. The wrapper now stops on key-file write failures and
propagates selection failures from discovery.

`discover-group` now waits for newly learned group activity instead of
immediately stopping on groups the linked device already knew about.

Selected group keys are first written to a same-directory temporary file and
then moved into place, so a failed write does not destroy the previously working
selection.
