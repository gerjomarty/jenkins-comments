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
    @post "/statuses/#{sha}", (state: "pending", description: process.env.PENDING_DESCRIPTION), (e, body) ->
      console.log e if e?

  pushErrorStatusForSha: (sha, targetUrl, description) =>
    description = "Tests with errors: " + description.join ", "
    @post "/statuses/#{sha}", (state: "error", target_url: targetUrl, description: description), (e, body) ->
      console.log e if e?

  pushFailureStatusForSha: (sha, targetUrl, description) =>
    description = "Failing tests: " + description.join ", "
    @post "/statuses/#{sha}", (state: "failure", target_url: targetUrl, description: description), (e, body) ->
      console.log e if e?

  # Test runs are stored in Redis under the key "<SHA>:<Jenkins job name>"
  findTestResult: (sha, test, cb) ->
    redis.hgetall "#{sha}:#{test}", (gErr, buildObj) ->
      ret = []
      ret = [buildObj.build_url, test] if buildObj.succeeded != "true"
      cb ret

  # This adds a test run to Redis based on the values passed to the constructor
  addTestToStore: (cb) =>
    redis.hmset "#{@sha}:#{@job_name}", {
      "job_number": @job_number,
      "build_url": @build_url,
      "user": @user,
      "repo": @repo,
      "succeeded": @succeeded
    }
    # Also have a Redis set per SHA to easily find all test runs of a particular commit
    redis.sadd @sha, @job_name
    cb null, @sha

  # This looks in the Redis set for the SHA and finds the tests already added
  findAllTests: (sha, cb) ->
    redis.smembers sha, (mErr, tests) ->
      cb null, sha, tests

  findAllTestResults: (sha, tests, cb) =>
    async.mapSeries tests,
      ((test, icb) =>
        @findTestResult(sha, test, ((ret) -> icb null, ret))),
      (err, results) ->
        cb null, sha, tests, results

  pushStatus: (sha, tests, results, cb) =>
    async.rejectSeries results,
      ((result, icb) -> icb (result.length == 0 ? true : false)),
      (failedTests) =>
        if failedTests.length == 0
          if tests.length == parseInt(process.env.NO_OF_INDIVIDUAL_TESTS)
            @pushSuccessStatusForSha sha
          else
            @pushPendingStatusForSha sha
          cb null, 'done'
        else
          failureUrl = failedTests[0][0]
          async.mapSeries failedTests,
            ((result, icb) -> icb null, result[1]),
            (err, jobDescriptions) =>
              @pushFailureStatusForSha sha, failureUrl, jobDescriptions
              cb null, 'done'

  # async.waterfall passes on the arguments given to the function callback to the next function in the waterfall
  updateStatus: (cb) ->
    async.waterfall [
      @addTestToStore,
      @findAllTests,
      @findAllTestResults,
      @pushStatus
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

    pusher = new StatusPusher sha, job_name, job_number, build_url, user, repo, succeeded
    pusher.updateStatus (e, r) -> console.log e if e?
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

    pusher = new StatusPusher sha, null, null, null, user, repo, null
    statuses = pusher.getStatusForSha sha
    pusher.pushPendingStatusForSha sha if statuses.length == 0

    res.send 201
  else
    res.send 404

app.listen app.settings.port
