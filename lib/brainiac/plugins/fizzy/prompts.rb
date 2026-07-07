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

          ### Retrieving Full Comment Text
          If you need the full text of a truncated comment, run: `fizzy comment show COMMENT_ID --card CARD_NUMBER`

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
          fizzy card show {{CARD_NUMBER}}
          fizzy comment list --card {{CARD_NUMBER}}
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
          When you're done, post a comment on the card with a concise summary, PR link, and branch name.

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

        UAT_TESTING = <<~'PROMPT'
          PR for card #{{CARD_NUMBER}} ("{{CARD_TITLE}}") has been merged to main (PR #{{PR_NUMBER}}).
          Run any UAT testing steps defined in the card or acceptance criteria.
          Post results as a comment on the card.
        PROMPT
      end
    end
  end
end
