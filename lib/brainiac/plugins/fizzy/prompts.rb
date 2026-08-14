# frozen_string_literal: true

module Brainiac
  module Plugins
    module Fizzy
      # Fizzy-specific prompt constants.
      # Registered with core via Brainiac.register_channel_prompt(:fizzy, ...).
      module Prompts
        CHANNEL = <<~PROMPT
          ## Fizzy Channel Rules

          ### Standard Procedure
          - If you have questions, ask them in the card's comments.
          - Only assign a fizzy card if it is currently unassigned and you are requested to work on it.

          ### Column Transitions
          Brainiac handles column moves automatically — do NOT move cards between columns yourself.
          Cards move to "Right Now" when you're dispatched and to "Needs Review" when your session ends.

          ### Formatting
          **Fizzy comments use HTML, NOT Markdown.** Use `<h2>`/`<h3>` for sections, `<p>` for paragraphs, `<ul><li>` for lists, `<pre data-language="ruby">` for code blocks, `<strong>` for emphasis. Never use markdown syntax in Fizzy comments.

          ### Screenshots (MANDATORY for UI changes)
          If you touched any `.js`, `.jsx`, `.css`, or `.html` in a web app directory and `./scripts/screenshot-page.sh` exists, screenshot every affected page.

          ### Fizzy CLI Tips
          - Use `--jq` for filtering output (built-in, never pipe to external jq): `fizzy card list --jq '[.data[] | {number, title}]'`
          - Use `fizzy search "query"` for cross-board full-text search
          - Use `fizzy card list --search "term"` for structured filtering within a board
          - Use `--agent` flag for raw JSON data without envelope when parsing output
          - Retrieve full comment text: `fizzy comment show COMMENT_ID --card CARD_NUMBER`

          ### Card Memory Discipline (CRITICAL for long-running cards)
          When writing your memory file for a Fizzy card session, include:
          - The original card scope/requirements
          - Any scope changes from comments
          - Any card body edits detected during pre-post check
          - The current scope/focus as of this session
        PROMPT

        PRE_POST_CHECK = <<~PROMPT
          ## Pre-Post Comment Check (MANDATORY — do this BEFORE posting your comment)

          Re-fetch the card to see if anything changed while you were working:

          ```bash
          fizzy card show {{CARD_NUMBER}} --jq '.data | {title, description, assignees: [.assignees[].name]}'
          fizzy comment list --card {{CARD_NUMBER}} --jq '[.data[-5:] | .[] | {creator: .creator.name, body: .body.plain_text}]'
          ```

          Compare against the card context from the start of your session. Check for:
          - Card body changes (new acceptance criteria, clarified scope)
          - New comments (requirements changes, adjustments, new context)

          If nothing changed, proceed normally.
        PROMPT

        CARD_ASSIGNED = <<~'PROMPT'
          You have been assigned Fizzy card #{{CARD_NUMBER}}: "{{CARD_TITLE}}".
          You are on branch "{{BRANCH}}" in a fresh worktree.
          Implement the task, commit, push, and open a PR (link back to Fizzy).

          **Response destination: Post your response as a comment on Fizzy card #{{CARD_NUMBER}}.**
          Your comment MUST include a concise summary of what you did, a PR link, and the branch name.

          **MANDATORY: Always include the branch name in your comment.** Use this format:
          `<p><strong>Branch:</strong> <code>{{BRANCH}}</code></p>`
        PROMPT

        FOLLOWUP_WORKTREE = <<~'PROMPT'
          There's a new comment on Fizzy card #{{CARD_NUMBER}} that you've already started working on.
          You are in the existing worktree for this card.

          The comment from {{COMMENT_CREATOR}} (comment ID: {{COMMENT_ID}}):
          """
          {{COMMENT_BODY}}
          """

          Focus your response on the comment above. If you've already addressed this in a previous session, reply confirming it's done.
          Otherwise, make the requested changes, commit, and push.

          **Response destination: Post your response as a comment on Fizzy card #{{CARD_NUMBER}}.**
          Do NOT post comments on the GitHub PR — this conversation is happening on the card.
        PROMPT

        FOLLOWUP_NO_WORKTREE = <<~PROMPT
          There's a new comment on a Fizzy card (internal_id: "{{CARD_INTERNAL_ID}}").

          The comment from {{COMMENT_CREATOR}} (comment ID: {{COMMENT_ID}}):
          """
          {{COMMENT_BODY}}
          """

          Focus your response on the comment above. If you've already addressed this, reply confirming it's done.
          Otherwise, respond accordingly.
        PROMPT

        MENTION = <<~PROMPT
          You were mentioned in a comment on a Fizzy card with internal_id "{{CARD_INTERNAL_ID}}"{{CARD_NUMBER_TEXT}}.
          You are on branch "{{BRANCH}}" in a dedicated worktree.

          Investigate the codebase and respond accordingly.
        PROMPT

        CROSS_AGENT_REVIEW = <<~'PROMPT'
          You were tagged in a comment on Fizzy card #{{CARD_NUMBER}} (internal_id: "{{CARD_INTERNAL_ID}}").
          This card is being worked on by {{CARD_AGENT}} — you're being brought in for your perspective.

          The comment from {{COMMENT_CREATOR}} (comment ID: {{COMMENT_ID}}):
          """
          {{COMMENT_BODY}}
          """

          You are in your own worktree at `{{WORKTREE_PATH}}` on branch `{{BRANCH}}`.
          Respond to what's being asked — code review, opinion, debugging help, or sanity check.

          **IMPORTANT: Do NOT @mention any other agents in your response.**
        PROMPT

        SUMMARIZE_WORK = <<~'PROMPT'
          You completed work on Fizzy card #{{CARD_NUMBER}} ("{{CARD_TITLE}}") but did not post a comment.
          Read your memory file for this card and write a brief summary comment.

          **Response destination: Post your response as a comment on Fizzy card #{{CARD_NUMBER}}.**
          Include what you did, any PR link, and the branch name.
          Keep it concise — this is a summary, not a full report.

          **MANDATORY: Always include the branch name in your comment.** Use this format:
          `<p><strong>Branch:</strong> <code>{{BRANCH}}</code></p>`
        PROMPT

        UAT_TESTING = <<~'PROMPT'
          PR for card #{{CARD_NUMBER}} ("{{CARD_TITLE}}") has been merged to main (PR #{{PR_NUMBER}}).
          Run any UAT testing steps defined in the card or acceptance criteria.
          Post results as a comment on the card.
        PROMPT

        PLANNING_MODE = <<~PROMPT
          ## Planning Mode (ACTIVE)

          You are in **planning mode**. Your job is to gather requirements and break down the work into actionable tasks.

          ### Your Role
          - Ask clarifying questions to understand the problem, constraints, and desired outcome
          - Continue asking until you have a clear picture (don't rush to a plan)
          - Understand user intent naturally — "go ahead", "that's enough", "proceed" all mean the same thing
          - When you have enough information OR the user signals they're ready, generate the plan

          ### Question Guidelines
          - Ask specific, focused questions (not generic "anything else?")
          - Build on previous answers — reference what you've learned
          - Prioritize questions that would significantly change the approach
          - If you're 90% confident, proceed. If you're 60% confident, ask.

          ### When to Stop Asking
          The user will signal they're ready in natural language:
          - "go ahead", "proceed", "that's enough", "looks good", "yeah do it"
          - "I think you have enough", "start working", "make the plan"

          You should also stop if:
          - You've asked 5+ questions and have a clear understanding
          - The user is getting impatient or frustrated
          - The remaining unknowns are minor details you can decide yourself

          ### Generating the Plan
          When ready, create a plan file at `{{PLAN_FILE}}` with this structure:

          ```markdown
          # Feature: [Title]

          ## Problem Statement
          [What we're solving and why]

          ## Requirements
          - Requirement 1
          - Requirement 2
          - Requirement 3

          ## Approach
          [High-level strategy and key decisions]

          ## Task Breakdown
          ### Task 1: [Clear, actionable title]
          - **Objective**: [What this task accomplishes]
          - **Approach**: [How to implement it]
          - **Demo**: [What "done" looks like]

          ### Task 2: [Clear, actionable title]
          - **Objective**: [What this task accomplishes]
          - **Approach**: [How to implement it]
          - **Demo**: [What "done" looks like]

          [Continue for all tasks...]
          ```

          ### Memory Management
          Log every question and answer to your memory file in this format:

          ```
          ## Planning Q&A
          Q: [Your question]
          A: [User's answer]

          Q: [Next question]
          A: [User's answer]
          ```

          Also track:
          - `planning_complete: false` (update to `true` when plan is generated)
          - Key decisions and constraints discovered
          - Any blockers or unknowns that remain

          ### After Planning
          Once you've written the plan file:
          1. Update memory with `planning_complete: true`
          2. Post a comment summarizing the plan and linking to the file
          3. The system will automatically create Fizzy steps from your task breakdown

          ### Important
          - You are READ-ONLY during planning — no code changes, no commits
          - Focus on understanding the problem, not solving it yet
          - The plan should be detailed enough that any agent could execute it
          - Task titles should be clear and actionable (they become Fizzy step names)

        PROMPT
      end
    end
  end
end
