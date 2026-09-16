package main

import "testing"

func TestHouseholdListRequest(t *testing.T) {
  input := interpreterInput{Message: "Add milk to Weekly shopping list"}
  proposal, ok := deterministicConversationProposal(input)
  if !ok || proposal.Type != "add_household_list_item" || proposal.Parameters["title"] != "milk" || proposal.Parameters["list_name"] != "Weekly shopping" {
    t.Fatalf("unexpected list proposal: %#v", proposal)
  }
  if !validateModelProposal(proposal,input.Context,input.Message) { t.Fatal("valid list action rejected") }
  proposal.Parameters["household_id"]="untrusted"
  if validateModelProposal(proposal,input.Context,input.Message) { t.Fatal("untrusted family override accepted") }
}
