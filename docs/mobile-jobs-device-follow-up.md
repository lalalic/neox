# Mobile Jobs physical-device follow-up

**Status:** `NOT_RUN`

**Owner:** Cheng Li (Job requester)

**Trigger:** After the authorized development build containing the Job 767 revision is installed on the paired iPhone.

## Run

1. Record the installed app version/build and the source commit. Use the already paired Neo Master and its existing authorized access; do not change Job state or expose credentials in evidence.
2. Open a visible non-cancelled Job in **Jobs**, pull to refresh, and open its details. Confirm its events remain visible while metadata starts collapsed. Expand and collapse the metadata once.
3. Compare the visible Job's activity with the Dashboard Job Events view for the same canonical Job ID and repository. Compare the latest 60 distinct events by event ID, order, type, timestamp, task ID, displayed message, and authorized details. Record event counts and every mismatch.
4. Confirm Job 763 remains `CANCELLED` and absent from the Jobs list. Since it must remain hidden, use a targeted, read-only authenticated detail/integration fixture for Job 763 on the iPhone and compare its canonical event history against the same Dashboard snapshot. Keep this check separate from the production list; do not restore, cancel, or otherwise modify Job 763.
5. Refresh once more and confirm the activity converges to the Dashboard snapshot without duplicate or missing events. Record any network or fixture limitation as `NOT_RUN` for the affected check.

## Record the result

Attach the installed build and commit identifiers, device model/iOS version, Dashboard and Mobile event counts, comparison mismatches, and pass/fail/`NOT_RUN` status for each step to the Job 767 Relay acceptance record. Keep this follow-up `NOT_RUN` until Cheng Li records the completed device result.
