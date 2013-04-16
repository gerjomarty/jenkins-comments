async = require 'async'
_     = require 'underscore'
_s    = require 'underscore.string'

GithubCaller = require('./github_caller').GithubCaller
StatusPusher = require('./status_pusher').StatusPusher

class exports.Commentator
  constructor: (@sha, @job_name, @job_number, @build_url, @user, @repo, @succeeded) ->
    pending_desc = eval("process.env.PENDING_DESCRIPTION_#{_s.underscored(@user).toUpperCase()}_#{_s.underscored(@repo).toUpperCase()}")
    @caller = new GithubCaller(@user, @repo, process.env.GITHUB_USER_TOKEN, process.env.USER_AGENT)
    @pusher = new StatusPusher(@user, @repo, @sha, pending_desc, @caller)
    @number_of_individual_tests = parseInt(eval("process.env.NO_OF_INDIVIDUAL_TESTS_#{_s.underscored(@user).toUpperCase()}_#{_s.underscored(@repo).toUpperCase()}"))

    if process.env.REDISTOGO_URL
      rtg   = require("url").parse process.env.REDISTOGO_URL
      redis = require("redis").createClient rtg.port, rtg.hostname
      redis.auth rtg.auth.split(":")[1]
    else
      redis = require("redis").createClient()

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
          if tests.length >= @number_of_individual_tests
            console.log "All #{tests.length} tests passed - pushing success status"
            @pusher.pushSuccess
          else
            console.log "#{tests.length}/#{@number_of_individual_tests} tests passed so far"
            @pusher.pushPending
          cb null, 'done'
        else
          failureUrl = failedTests[0][0]
          async.mapSeries failedTests,
            ((result, icb) -> icb null, result[1]),
            (err, jobDescriptions) =>
              console.log "At least one test failed - pushing failure status"
              @pusher.pushFailure failureUrl, jobDescriptions
              cb null, 'done'

  # async.waterfall passes on the arguments given to the function callback to the next function in the waterfall
  updateStatus: (cb) ->
    async.waterfall [
      @addTestToStore,
      @findAllTests,
      @findAllTestResults,
      @pushStatus
    ], cb