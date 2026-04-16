---
name: linear-api
description: Linear API patterns for posting comments and transitioning issue states.
---

Post comments and transition states using curl. The API key is $LINEAR_API_KEY.

## Find your existing comment (check before posting a new one)

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ issue(id: \"{{ issue.id }}\") { comments { nodes { id body user { name } } } } }"}' \
  | jq '.data.issue.comments.nodes[] | select(.user.name == "clanker") | .id' -r
```

## Update an existing comment (use commentUpdate, not commentCreate)

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation($id:String!,$input:CommentUpdateInput!){commentUpdate(id:$id,input:$input){success}}","variables":{"id":"COMMENT_ID","input":{"body":"UPDATED BODY"}}}'
```

## Create a new comment (only if none exists from you)

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation($input:CommentCreateInput!){commentCreate(input:$input){success comment{id}}}","variables":{"input":{"issueId":"{{ issue.id }}","body":"YOUR COMMENT"}}}'
```

## Move to In Review

State ID: 20082009-96a4-467f-a38d-d0e418206baf

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation{issueUpdate(id:\"{{ issue.id }}\",input:{stateId:\"20082009-96a4-467f-a38d-d0e418206baf\"}){success}}"}'
```
