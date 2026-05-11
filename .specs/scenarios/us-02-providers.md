# US-02: Manage providers

## S-02.1: View providers list
**Given** the user opens Settings
**When** they scroll to the Providers section
**Then** they see a list of configured providers with an "Add Provider" button

## S-02.2: Add a new provider
**Given** the user is on the Providers section
**When** they tap "Add Provider"
**Then** an add-provider form appears where they can enter name, base URL, and API key

## S-02.3: Test provider connection
**Given** the user has added a provider with valid credentials
**When** they tap "Test Connection"
**Then** the app tests the connection and shows a success/failure indicator

## S-02.4: Delete a provider
**Given** the user has at least one custom provider
**When** they delete a provider
**Then** the provider is removed from the list and its models are no longer available
