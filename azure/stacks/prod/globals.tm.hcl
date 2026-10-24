globals {
  subscription_id                 = "22222222-2222-2222-2222-222222222222"   # Azure subscription id (GUID)
  state_contributor_principal_ids = ["44444444-4444-4444-4444-444444444444"] # Entra ID object ids that read and write the state
  protect_destroy                 = true
}
