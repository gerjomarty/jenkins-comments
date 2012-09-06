async   = require 'async'
request = require 'request'
express = require 'express'
_       = require 'underscore'
_s      = require 'underscore.string'

if process.env.REDISTOGO_URL
  rtg   = require("url").parse process.env.REDISTOGO_URL
  redis = require("redis").createClient rtg.port, rtg.hostname
  redis.auth rtg.auth.split(":")[1]
else
  redis = require("redis").createClient()

class StatusPusher
  constructor: (@sha, @job_name, @job_number, @build_url, @user, @repo, @succeeded) ->
    @api = "https://api.github.com/repos/#{@user}/#{@repo}"
    @token = "?access_token=#{process.env.GITHUB_USER_TOKEN}"

  post: (path, obj, cb) =>
    console.log "POST #{@api}#{path}#{@token}"
    console.dir obj
    request.post { uri: "#{@api}#{path}#{@token}", json: obj }, (e, r, body) ->
      console.log body if process.env.DEBUG
      cb e, body

  get: (path, cb) =>
    console.log "GET #{@api}#{path}#{@token}"
    request.get { uri: "#{@api}#{path}#{@token}", json: true }, (e, r, body) ->
      console.log body if process.env.DEBUG
      cb e, body

  getStatusForSha: (sha, cb) =>
    @get "/statuses/#{sha}", cb

  pushSuccessStatusForSha: (sha) =>
    @post "/statuses/#{sha}", (state: "success"), (e, body) ->
      console.log e if e?

  pushPendingStatusForSha: (sha) =>
    @post "/statuses/#{sha}", (state: "pending"), (e, body) ->
      console.log e if e?

  pushErrorStatusForSha: (sha, targetUrl, description) =>
    description = "Tests with errors: " + description.join ", "
    @post "/statuses/#{sha}", (state: "error", target_url: targetUrl, description: description), (e, body) ->
      console.log e if e?

  pushFailureStatusForSha: (sha, targetUrl, description) =>
    description = "Failing tests: " + description.join ", "
    @post "/statuses/#{sha}", (state: "failure", target_url: targetUrl, description: description), (e, body) ->
      console.log e if e?

  findTestResult: (sha, test) ->
    redis.hgetall "#{sha}:#{test}", (gErr, buildObj) ->
      console.log "hgetall for #{sha}:#{test}..."
      console.dir buildObj
      if buildObj.succeeded == "true"
        return []
      else
        return [buildObj.build_url, buildObj.job_name]

  addTestToStore: (cb) =>
    console.log "sha and job name"
    console.dir @sha
    console.dir @job_name
    redis.hmset "#{@sha}:#{@job_name}", {
      "job_number": @job_number,
      "build_url": @build_url,
      "user": @user,
      "repo": @repo,
      "succeeded": @succeeded
    }
    redis.sadd @sha, @job_name
    cb null, @sha

  findAllTests: (sha, cb) ->
    redis.smembers sha, (mErr, tests) ->
      console.log "smembers..."
      console.dir tests
      cb null, sha, tests

  findAllTestResults: (sha, tests, cb) =>
    async.map tests,
      ((test, icb) => icb null, findTestResult(sha, test)),
      (err, results) ->
        console.log "found all test results"
        console.dir results
        cb null, sha, tests, results

  pushStatus: (sha, tests, results, cb) =>
    async.reject results,
      ((result, icb) -> icb (result.length == 0)),
      (failedTests) =>
        console.log "failed tests"
        console.dir failedTests
        if failedTests.length == 0
          if tests.length == 3
            console.log "success"
            @pushSuccessStatusForSha sha
          else
            console.log "pending"
            @pushPendingStatusForSha sha
          cb null, 'done'
        else
          failureUrl = failedTests[0][0]
          async.map failedTests,
            ((result, icb) -> icb null, result[1]),
            (err, jobDescriptions) =>
              console.log "failure"
              console.dir failureUrl
              console.dir jobDescriptions
              @pushFailureStatusForSha sha, failureUrl, jobDescriptions
              cb null, 'done'

  updateStatus: (cb) ->
    async.waterfall [
      @addTestToStore,
      @findAllTests,
      @findAllTestResults,
      @pushStatus
    ], cb




class PullRequestCommenter
  BUILDREPORT = "**Build Status**:"

  constructor: (@sha, @job_name, @job_number, @build_url, @user, @repo, @succeeded) ->
    @api = "https://api.github.com/repos/#{@user}/#{@repo}"
    @token = "?access_token=#{process.env.GITHUB_USER_TOKEN}"

  post: (path, obj, cb) =>
    console.log "POST #{@api}#{path}#{@token}"
    console.dir obj
    request.post { uri: "#{@api}#{path}#{@token}", json: obj }, (e, r, body) ->
      console.log body if process.env.DEBUG
      cb e, body

  get: (path, cb) =>
    console.log "GET #{@api}#{path}#{@token}"
    request.get { uri: "#{@api}#{path}#{@token}", json: true }, (e, r, body) ->
      console.log body if process.env.DEBUG
      cb e, body

  del: (path, cb) =>
    console.log "DELETE #{@api}#{path}#{@token}"
    request.del { uri: "#{@api}#{path}#{@token}" }, (e, r, body) ->
      console.log body if process.env.DEBUG
      cb e, body

  getCommentsForIssue: (issue, cb) =>
    @get "/issues/#{issue}/comments", cb

  deleteComment: (id, cb) =>
    @del "/issues/comments/#{id}", cb

  getPulls: (cb) =>
    @get "/pulls", cb

  getPull: (id, cb) =>
    @get "/pulls/#{id}", cb

  commentOnIssue: (issue, comment) =>
    @post "/issues/#{issue}/comments", (body: comment), (e, body) ->
      console.log e if e?

  successComment: ->
    "**#{@job_name}**\n#{BUILDREPORT} :green_heart: `Succeeded` (#{@sha}, [job info](#{@build_url}))"

  errorComment: ->
    "**#{@job_name}**\n#{BUILDREPORT} :broken_heart: `Failed` (#{@sha}, [job info](#{@build_url}))"

  # Find the first open pull with a matching HEAD sha
  findMatchingPull: (pulls, cb) =>
    pulls = _.filter pulls, (p) => p.state is 'open'
    async.detect pulls, (pull, detect_if) =>
      @getPull pull.number, (e, { head }) =>
        return cb e if e?
        detect_if head.sha is @sha
    , (match) =>
      return cb "No pull request for #{@sha} found" unless match?
      cb null, match

  removePreviousPullComments: (pull, cb) =>
    @getCommentsForIssue pull.number, (e, comments) =>
      return cb e if e?
      old_comments = _.filter comments, ({ body }) -> _s.include body, BUILDREPORT
      async.forEach old_comments, (comment, done_delete) =>
        @deleteComment comment.id, done_delete
      , () -> cb null, pull

  makePullComment: (pull, cb) =>
    comment = if @succeeded then @successComment() else @errorComment()
    @commentOnIssue pull.number, comment
    cb()

  updateComments: (cb) ->
    async.waterfall [
      @getPulls
      @findMatchingPull
      #@removePreviousPullComments
      @makePullComment
    ], cb

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
    <a href="https://github.com/cramerdev/jenkins-comments">
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

    # Store the status of this sha for later
    #redis.hmset sha, {
    #  "job_name": job_name,
    #  "job_number": job_number,
    #  "build_url": build_url,
    #  "user": user,
    #  "repo": repo,
    #  "succeeded": succeeded
    #}

    # Look for an open pull request with this SHA and make comments.
    #commenter = new PullRequestCommenter sha, job_name, job_number, build_url, user, repo, succeeded
    #commenter.updateComments (e, r) -> console.log e if e?

    pusher = new StatusPusher sha, job_name, job_number, build_url, user, repo, succeeded
    pusher.updateStatus (e, r) -> console.log e if e?
    res.send 200
  else
    res.send 400

# GitHub lets us know when a pull request has been opened.
app.post '/github/post_receive', (req, res) ->
  payload = JSON.parse req.body.payload
  console.log "post receive payload"
  console.dir payload

  if payload.pull_request
    sha = payload.pull_request.head.sha

    ## Get the sha status from earlier and insta-comment the status
    #redis.hgetall sha, (err, obj) ->
    #  # Convert stored string to boolean
    #  obj.succeeded = (obj.succeeded == "true" ? true : false)

    #  commenter = new PullRequestCommenter sha, obj.job_name, obj.job_number, obj.build_url, obj.user, obj.repo, obj.succeeded
    #  commenter.updateComments (e, r) -> console.log e if e?

    # Mark the commit as pending.
    pusher = new StatusPusher
    pusher.pushPendingStatusForSha sha

    res.send 201
  else
    res.send 404

app.listen app.settings.port
