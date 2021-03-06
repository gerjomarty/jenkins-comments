_ = require 'underscore'

RestCaller = require('./rest_caller').RestCaller

class exports.JiraCaller extends RestCaller
  constructor: (base_uri, bot_username, bot_password, query, user_agent) ->
    basic_auth = new Buffer("#{bot_username}:#{bot_password}").toString('base64')
    super("#{base_uri}/rest/api/2", query, user_agent, {"Authorization": "Basic #{basic_auth}"})

  getTransitions: (issue_key, cb) =>
    @get "/issue/#{issue_key}/transitions", (e, body) ->
      cb e, body.transitions

  postTransition: (issue_key, transition_id, comment, cb) =>
    post_body = {
      "update": {
        "comment": [{"add": {"body": comment}}]
      },
      "transition": {
        "id": transition_id.toString()
      }
    }
    @post "/issue/#{issue_key}/transitions", post_body, (e, body) ->
      cb e

  findTransition: (transitions, transition_name, cb) =>
    cb _.findWhere(transitions, {"name": transition_name})

  makeTransition: (issue_key, transition_name, comment, cb) =>
    @getTransitions issue_key, (getErr, transitions) =>
      if getErr?
        cb getErr
      else
        @findTransition transitions, transition_name, (transition) =>
          if transition?
            @postTransition issue_key, transition.id, comment, (postErr) ->
              cb postErr
          else
            cb {jira_error: {transition_not_found: {transition_name: transition_name, issue_key: issue_key}}}

  moveIssueToCodeReview: (issue_key, comment, cb) =>
    @makeTransition issue_key, "Dev Complete", comment, (e) =>
      if e? and e.jira_error? and e.jira_error.transition_not_found?
        @makeTransition issue_key, "Start Code Review", comment, cb
      else
        cb e

  passedCodeReview: (issue_key, comment, cb) =>
    @makeTransition issue_key, "Passed Code Review", comment, (e) =>
      if e? and e.jira_error? and e.jira_error.transition_not_found?
        @makeTransition issue_key, "Pass Code Review", comment, cb
      else
        cb e

  failedCodeReview: (issue_key, comment, cb) =>
    @makeTransition issue_key, "Failed Code Review", comment, cb
