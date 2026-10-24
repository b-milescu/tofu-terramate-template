globals {
  subscription_id                 = "11111111-1111-1111-1111-111111111111"   # Azure subscription id (GUID)
  state_contributor_principal_ids = ["33333333-3333-3333-3333-333333333333"] # Entra ID object ids that read and write the state
  protect_destroy                 = false
}
