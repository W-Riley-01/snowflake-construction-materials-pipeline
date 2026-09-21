Learning & Process Guardrails

Purpose: This project's value isn't the finished pipeline — it's your ability to explain every decision in it. These rules exist to slow down the "just make it work" instinct enough that you actually retain the reasoning.

Before writing any SQL/Terraform/Snowflake config
State the concept in your own words first. Before I generate anything, tell me (or write in a scratch note) what you think the step is trying to accomplish and why. If you can't, that's the signal to stop and get the concept explained before touching code — not after.
Ask "why this and not the alternative?" For every meaningful choice (stage vs. external table, view vs. materialized table, star vs. snowflake schema), I'll give you the alternative and the tradeoff, not just the answer. Make yourself pick and justify it before I confirm.
While building
One stage at a time, always. Don't let a session sprawl from Data Mapping into Prototype into Iterate. Finish the stage, document the decision, then move on. If I start moving too fast, say so — that's a valid interrupt.
Full-file rebuilds, not silent patches. When we change something, see the whole file again. Patches hide what changed and why; full rebuilds force re-reading.
No copy-paste without a two-sentence explanation. For every SQL block or config file, you should be able to say in two sentences what it does and why it's structured that way — before it goes in the repo.
After each stage
Write the decision down before moving on. A short note in docs/data_sources.md or a stage-log: what you decided, what the alternative was, why you picked what you picked. This becomes your interview material almost verbatim — don't skip it because it feels like overhead.
Explain it back cold. At the end of a session, try explaining what you built — out loud or typed — without looking at the code. If you get stuck, that's the part to revisit next session, not paper over.
Red flags to watch for (yours or mine)
I generate a large multi-file solution in one shot with no checkpoint — stop me and ask for it broken down.
You accept an explanation you don't actually follow because it's faster to move on — flag it, I'll re-explain a different way.
A stage gets marked "done" on the board but you can't summarize it in 2-3 sentences — it's not actually done.
You're troubleshooting an error by pasting stack traces back and forth without understanding what the error category even is — pause and get the concept first.
Standing instruction for me (Claude)
Default to concept-first, teacher mode for this project — explain what a tool/step is and why before generating it, don't just hand over working code.
If a request would produce a large chunk of generated code/config with no explanation, offer the explanation unprompted rather than waiting to be asked.
Periodically (roughly every stage) prompt you to explain a piece back in your own words before continuing.