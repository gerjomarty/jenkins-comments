RestCaller = require('./rest_caller').RestCaller

class exports.GithubCommenter extends RestCaller
  constructor: (user, repo, user_token, user_agent) ->
    super("https://api.github.com/#{user}/#{repo}", {access_token: user_token}, user_agent, null)

  postCommentOnIssue: (issue_number, comment, cb) =>
    @post "/issues/#{issue_number}/comments", (body: comment), (e, body) ->
      cb e