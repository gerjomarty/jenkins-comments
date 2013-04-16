express = require 'express'

GithubCaller = require('./github_caller').GithubCaller
StatusPusher = require('./status_pusher').StatusPusher
Commentator  = require('./commentator').Commentator

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

  if payload.pull_request
    sha = payload.pull_request.head.sha
    user = payload.pull_request.head.user.login
    repo = payload.pull_request.head.repo.name
    console.log "Github received commit SHA #{sha}"

    pending_desc = eval("process.env.PENDING_DESCRIPTION_#{_s.underscored(user).toUpperCase()}_#{_s.underscored(repo).toUpperCase()}")

    caller = new GithubCaller(user, repo, process.env.GITHUB_USER_TOKEN, process.env.USER_AGENT)
    pusher = new StatusPusher(user, repo, sha, pending_desc, caller)

    pusher.getStatus (e, statuses) ->
      console.log e if e?
      if statuses.length == 0
        console.log "No existing statuses for SHA #{sha}"
        pusher.pushPending
      else
        console.log "Existing statuses for SHA #{sha}"
      res.send 201
  else
    res.send 404

app.listen app.settings.port
