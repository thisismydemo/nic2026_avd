// Gap-fill: subscription budget with mixed Actual (50/80/100 %) and Forecasted (100 %) thresholds — design §2.3.
// Why gap-fill: AVM consumption/budget 0.3.8 applies one thresholdType to every threshold; the design needs both kinds
// in one budget.
targetScope = 'subscription'

param name string
param amount int
param contact_emails array
param action_group_id string

@description('First day of the current month; budgets must start on the first of a month.')
param start_date string = utcNow('yyyy-MM-01')

resource budget 'Microsoft.Consumption/budgets@2026-06-01' = {
  name: name
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: start_date
    }
    notifications: {
      actual50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: contact_emails
        contactGroups: [action_group_id]
      }
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: contact_emails
        contactGroups: [action_group_id]
      }
      actual100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: contact_emails
        contactGroups: [action_group_id]
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: contact_emails
        contactGroups: [action_group_id]
      }
    }
  }
}

output budget_id string = budget.id
