# Working rules for this repo

Read `learning-guardrails.md` before doing anything. It governs this project.

Non-negotiables:
- Concept-first. Explain what a step is and why before generating SQL.
- ONE stage at a time. Do not build ahead.
- Full-file rebuilds, not patches.
- For every design choice: present the alternative and the cost, and wait
  for me to pick. Do not decide for me.
- Log every decision with its rejected alternative in docs/data_sources.md
  before moving on.

Do NOT scaffold the MART layer unprompted. The grain decision for
fact_production is unresolved and is mine to make.