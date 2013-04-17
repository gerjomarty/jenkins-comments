RestCaller = require('./rest_caller').RestCaller

class exports.GithubCommenter extends RestCaller
  constructor: (user, repo, user_token, user_agent) ->
    super("https://api.github.com/repos/#{user}/#{repo}", {access_token: user_token}, user_agent, null)

  postCommentOnIssue: (issue_number, comment, cb) =>
    @post "/issues/comments/#{issue_number}", (body: comment), (e, body) ->
      cb e