express = require 'express'
_s      = require 'underscore.string'

GithubCaller    = require('./github_caller').GithubCaller
StatusPusher    = require('./status_pusher').StatusPusher
GithubCommenter = require('./github_commenter').GithubCommenter
Commentator     = require('./commentator').Commentator
JiraCaller      = require('./jira_caller').JiraCaller

JIRA_ISSUE_REGEXP = /^[A-Za-z]+-\d+/

app = module.exports = express.createServer()

app.configure ->
  app.use express.bodyParser()

app.configure 'development', ->
  app.set "port", 3000

app.configure 'production', ->
  app.use express.errorHandler()
  app.set "port", parseInt process.env.PORT

# Route for uptime pings and general curiosity
app.get '/', (req, res) ->
  res.send '
    <a href="https://github.com/gerjomarty/jenkins-comments">
      jenkins-comments
    </a>
  ', 200

# Jenkins lets us know when a build has failed or succeeded.
app.get '/jenkins/post_build', (req, res) ->
  sha = req.param 'sha'

  if sha
    job_name = req.param 'job_name'
    job_number = parseInt req.param 'job_number'
    build_url = req.param 'build_url'
    user = req.param 'user'
    repo = req.param 'repo'
    succeeded = req.param('status') is 'success'

    console.log "Jenkins completed test run for #{job_name} - SHA #{sha}"
    commentator = new Commentator(sha, job_name, job_number, build_url, user, repo, succeeded)
    commentator.updateStatus (e, r) -> console.log e if e?
    res.send 200
  else
    res.send 400

# GitHub lets us know when a pull request has been opened.
app.post '/github/post_receive', (req, res) ->
  payload = JSON.parse req.body.payload
  console.log req.body if process.env.DEBUG

  if payload.pull_request
    sha = payload.pull_request.head.sha
    user = payload.pull_request.head.user.login
    repo = payload.pull_request.head.repo.name
    console.log "Github received commit SHA #{sha}"

    pending_desc = eval("process.env.PENDING_DESCRIPTION_#{_s.underscored(user).toUpperCase()}_#{_s.underscored(repo).toUpperCase()}")
    github_caller = new GithubCaller(user, repo, process.env.GITHUB_USER_TOKEN, process.env.USER_AGENT)
    pusher = new StatusPusher(user, repo, sha, pending_desc, github_caller)
    github_commenter = new GithubCommenter(user, repo, process.env.GITHUB_USER_TOKEN, process.env.USER_AGENT)

    pusher.getStatus (e, statuses) ->
      console.log e if e?
      number_of_individual_tests = parseInt(eval("process.env.NO_OF_INDIVIDUAL_TESTS_#{_s.underscored(user).toUpperCase()}_#{_s.underscored(repo).toUpperCase()}"))
      if number_of_individual_tests > 0
        if statuses.length == 0
          console.log "No existing statuses for SHA #{sha}"
          pusher.pushPending
        else
          console.log "Existing statuses for SHA #{sha}"

    jira_base_uri = process.env.JIRA_BASE_URI
    jira_bot_username = process.env.JIRA_BOT_USERNAME
    jira_bot_password = process.env.JIRA_BOT_PASSWORD

    if jira_base_uri? and jira_bot_username? and jira_bot_password?
      jira_caller = new JiraCaller(jira_base_uri, jira_bot_username, jira_bot_password, null, process.env.USER_AGENT)
      jira_issue_key = JIRA_ISSUE_REGEXP.exec payload.pull_request.head.ref
      switch payload.action
        when "opened", "reopened"
          jira_caller.moveIssueToCodeReview jira_issue_key, process.env.JIRA_MOVE_TO_CODE_REVIEW_COMMENT, (e) ->
            if e? and e.jira_error? and e.jira_error.transition_not_found?
              github_commenter.postCommentOnIssue payload.number, "JIRA issue #{jira_issue_key} in incorrect state. Please move to Code Review manually.", (postErr) ->
                console.log postErr if postErr?
            else
              console.log e if e?
        when "closed"
          if payload.pull_request.merged
            jira_caller.passedCodeReview jira_issue_key, process.env.JIRA_PASSED_CODE_REVIEW_COMMENT, (e) ->
              if e? and e.jira_error? and e.jira_error.transition_not_found?
                github_commenter.postCommentOnIssue payload.number, "JIRA issue #{jira_issue_key} in incorrect state. Please move to QA manually.", (postErr) ->
                  console.log postErr if postErr?
              else
                console.log e if e?
          else
            jira_caller.failedCodeReview jira_issue_key, process.env.JIRA_FAILED_CODE_REVIEW_COMMENT, (e) ->
              if e? and e.jira_error? and e.jira_error.transition_not_found?
                github_commenter.postCommentOnIssue payload.number, "JIRA issue #{jira_issue_key} in incorrect state. Please move to In Progress manually.", (postErr) ->
                  console.log postErr if postErr?
              else
                console.log e if e?

    res.send 201
  else
    res.send 404

app.listen app.settings.port
