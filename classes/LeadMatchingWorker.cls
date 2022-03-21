/**
 * @description       : 
 * @author            : Marta Huertas
 * @group             : 
 * @last modified on  : 2021-07-16
 * @last modified by  : Miguel Ignacio Barragan
 * Modifications Log 
 * Ver   Date         Author          Modification
 * 1.0   26-01-2021   Marta Huertas   Initial Version
**/
@SuppressWarnings('PMD.AvoidGlobalModifier')
global with sharing class LeadMatchingWorker extends AbstractWorker {

    //#region VARIABLES DECLARATIONS
    @TestVisible
    private static Boolean forceAssignmentRules = false;

    public static final String ASSIGNED_STATUS = 'Assigned';
    public static final String ACCOUNT_CUSTOMER_PARTNER_RT = 'A02';
    public static final String FORCE_ASSIGNMENT_RULES_PERMISSION = 'Fire_Assignment_Rules_on_MQL';
    public static final String LEAD_CUSTOMER_RT = 'Customer';
    public static final String LEAD_PARTNER_RT = 'Partner';
    public static final String LEAD_DEAL_REGISTER_RT = 'L03';
    public static final String LEAD_INTEGROMAT04_RT = 'L04_Integromat_App_Partner';
    public static final String LEAD_INTEGROMAT05_RT = 'L05_Integromat_Integration_Partner';
    public static final String LEAD_INTEGROMAT06_RT = 'L06_Integromat_Software';

    private Map<String, Map<Id, Account>> accountByNameOrId = new Map<String, Map<Id, Account>>();
    private Lead[] leadsToFuzzyMatch = new Lead[]{};
    private Map<Id, rvpe__RVAccount__c> rvAccountsById = new Map<Id, rvpe__RVAccount__c>();
    private Lead[] notAssignedLeads = new Lead[]{};
    //#endregion

    //#region WORKER ROUTING
    public override void bulkBeforeInsert() {
        this.prepareRelatedAccountData((Lead[]) this.getNewRecords());
    }
     public override void bulkBeforeUpdate() {
        this.prepareRelatedAccountData((Lead[]) this.getNewRecords());
    }

    public override void beforeInsert(SObject newRecord) {
        Lead leadRecord = (Lead) newRecord;
        
        this.matchLead(leadRecord);
        
        //MIB-03/08/2021-Condition was added to avoid trying to assign a not matched Lead unless Lead type is L03
        if (leadRecord.Matching_Status__c == 'Completed' || Utils.getDevNameForRecordTypeId(Lead.sObjectType, leadRecord.RecordTypeId) == LEAD_DEAL_REGISTER_RT)
        	this.assignLead(null, leadRecord);
    }

    public override void beforeUpdate(SObject oldRecord, SObject newRecord) {
        Lead oldLead = (Lead)oldRecord;
        Lead newLead = (Lead)newRecord;
         
        if(oldLead.Matching_Status__c != newLead.Matching_Status__c && newLead.Matching_Status__c == 'Pending')
            this.matchLead(newLead);
        else if (oldLead.RelatedAccount__c != newLead.RelatedAccount__c && newLead.RelatedAccount__c != null) {
            //MIB-30/11/2021-Added to evaluate the Lead RT also if the related account change
            LeadMatchingHelper.changeLeadRecordType(newLead, this.accountByNameOrId.get(newLead.RelatedAccount__c).get(newLead.RelatedAccount__c).RecordType.DeveloperName);
        }
        
		this.assignLead(oldLead, newLead);
    }

    public override void andFinallyAfter() {        
        this.launchAssignmentBatch();
        this.cleanUp();
        
        //MIB-23/08/2021-Logs insertion. It was throwing insertion errors during test classes execution, that's the reason of the if clause
       	LogWorker.insertGeneratedLogStack();
    }
    //#endregion

    //#region DATA PREPARATION
    /**
     * @description Prepares the information of the accounts which could match with the leads
     * @author Marta Huertas | 09-03-2021 
     * @param leads - lead records to prepare the data
     **/
    public void prepareRelatedAccountData(Lead[] leads) {
        Set<String> accountIdsAndNames = new Set<String>();
        Set<Id> rvAccounts = new Set<Id>();

        for (Lead leadRec : leads) {
            if (String.isNotBlank(leadRec.Influencing_Partner__c)) {
                accountIdsAndNames.add(leadRec.Influencing_Partner__c);
            }

            if (String.isNotBlank(leadRec.rvpe__RVAccount__c)) {
                rvAccounts.add(leadRec.rvpe__RVAccount__c);
            }

            if (String.isNotBlank(leadRec.Company)) {
                accountIdsAndNames.add(leadRec.Company);
            }

            if (String.isNotBlank(leadRec.Ultimate_Parent_Account__c)) {
                accountIdsAndNames.add(leadRec.Ultimate_Parent_Account__c);
            }

            if (String.isNotBlank(leadRec.RelatedAccount__c)) {
                accountIdsAndNames.add(leadRec.RelatedAccount__c);
            }
        }

        this.rvAccountsById = LeadContextSelector.getRVAccountById(rvAccounts);

        for (rvpe__RVAccount__c rvAccount : this.rvAccountsById.values()) {
            accountIdsAndNames.add(rvAccount.rvpe__SFAccount__c);
        }

        this.accountByNameOrId = LeadContextSelector.getAccountsByIdOrName(accountIdsAndNames);
    }
    //#endregion
    
    //#region MATCHING
    /**
    * @description Checks if exists an account with the exact name of the lead's company, if not it will be reviewed by the batch
    * @author Marta Huertas | 09-03-2021 
    * @param leadRec - lead record to be matched
    **/
    public void matchLead(Lead leadRec) {
        //THIS METHOD IS NOT USING THE INFLUENCING PARTNER FOR MATCHING -> TO BE REVIEWED
        //MIB-09/03/2022-Added to avoid to rematch the lead if there is a related account already on it
        if (leadRec.RelatedAccount__c == null) {
            if (this.accountByNameOrId.containsKey(leadRec.Company)) {
                Map<Id, Account> matchingByName = this.accountByNameOrId.get(leadRec.Company);
    
                if (matchingByName.size() == 1) {
                    Account matchingAccount = matchingByName.values()[0];
                    
                    this.fillMatchingData(leadRec, matchingAccount);
                    
                    /*MIB-24/08/2021-New rule was added*/
                    LeadMatchingHelper.changeLeadRecordType(leadRec, matchingAccount.RecordType.DeveloperName);
                } else{ 
                    this.resetLeadAndPrepareForMatchingRules(leadRec);
                }
                
            } else{
                this.resetLeadAndPrepareForMatchingRules(leadRec);
            }
            
            LogWorker.createLogRecord(Datetime.now().millisecond(), leadRec.Id, 'Lead', Utils.getDevNameForRecordTypeId(Lead.sObjectType, leadRec.RecordTypeId),
                                      'LeadMatchingWorker.matchLead', 'Apex Class', 'Lead Matching Status: ' + leadRec.Matching_Status__c);
        }
    }

    /**
    * @description Populates the information of the account in the lead
    * @author Marta Huertas | 09-03-2021 
    * @param leadRec            - lead record to set the matching data to
    * @param matchingAccount    - account to abtain the matching data
    **/
    private void fillMatchingData(Lead leadRec, Account matchingAccount) {
		LogWorker.createLogRecord(Datetime.now().millisecond(), leadRec.Id, 'Lead', Utils.getDevNameForRecordTypeId(Lead.sObjectType, leadRec.RecordTypeId),
                                  'LeadMatchingWorker.fillMatchingData', 'Apex Class', 'Lead matched. Related Account: ' + matchingAccount.Name + '. Ultimate Parent Account: ' + matchingAccount.Ultimate_Parent_Account__c);
        
        leadRec.Matching_Status__c = 'Completed'; 
        leadRec.RelatedAccount__c = matchingAccount.Id;
        //leadRec.Sales_Territory__c = matchingAccount.Sales_Territory__c;
        leadRec.Ultimate_Parent_Account__c = (matchingAccount.Ultimate_Parent_Account__c != null) ? matchingAccount.Ultimate_Parent_Account__c : matchingAccount.Id;
    }

    /**
     * @description Reset the matching information of the lead
     * @param leadRec - lead record to reset
     */
    private void resetLeadAndPrepareForMatchingRules(Lead leadRec) {
		LogWorker.createLogRecord(Datetime.now().millisecond(), leadRec.Id, 'Lead', Utils.getDevNameForRecordTypeId(Lead.sObjectType, leadRec.RecordTypeId),
                                  'LeadMatchingWorker.resetLeadAndPrepareForMatchingRules', 'Apex Class', 'Lead was not matched.');
        
        leadRec.Matching_Status__c = 'Pending';
        leadRec.RelatedAccount__c = null;
        leadRec.Ultimate_Parent_Account__c = null;
        leadRec.Sales_Territory__c = null;
        this.leadsToFuzzyMatch.add(leadRec);
    }

    /**
     * @description Obtain only records that managed to get committed
     * @param records - records to obtain their respective identifiers
     * @return  record identifiers
     */
    private Set<Id> getIdsFromList(SObject[] records) {

        Set<Id> ids = new Set<Id>();
        for (SObject sobj : records) {
            if (String.isNotBlank(sobj.Id)) {
                ids.add(sobj.Id);
            }
        }
        return ids; 
    }
    
    /**
     * @description Obtain only leads that managed to get committed
     * @return  lead identifiers
     */
    public Set<Id> getLeadIdsToMatchByMatchingRules() {
        return this.getIdsFromList(this.leadsToFuzzyMatch); 
    }
    //#endregion
    
    //#region ASSIGNMENT
    /**
     * @description Assign the lead based on a related account and it's record type
     * @param oldLead - lead previous version
     * @param leadRec - lead new version
     */
    public void assignLead(Lead oldLead, Lead leadRec) {
    	LeadMatchingHelper.assignLead(oldLead, leadRec, accountByNameOrId);
        
        //MIB-14/12/2021-Moved from the end of assignOwerViaRelatedAccountOrUltimateAccount to here to be used for all the Lead RT
        if (!leadRec.Custom_Assigned__c) {
            this.notAssignedLeads.add(leadRec);
            
            LogWorker.createLogRecord(Datetime.now().millisecond(), leadRec.Id, 'Lead', Utils.getDevNameForRecordTypeId(Lead.sObjectType, leadRec.RecordTypeId), 'LeadMatchingWorker.assignLead', 'Apex Class',
                                      'Lead was not custom assigned so assignment rules will be used on it');
        }
    }
    
    /**
    * @description Launches the batch which will check if there is any matching account by fuzzy name or email domain 
    for the leads which don't have an exact company name match
	* @author Marta Huertas | 09-03-2021
	* @update MIB-03/08/2021-Unnecesary lines were deleted without change the logic
    **/
    public void launchAssignmentBatch() {       
        Set<Id> leadIdstoForceAssignmentRules = this.getIdsFromList(this.notAssignedLeads);

        if (!this.leadsToFuzzyMatch.isEmpty()) {
            LogWorker.createLogRecord(Datetime.now().millisecond(), leadsToFuzzyMatch[0].Id, 'Lead', '', 'LeadMatchingWorker.launchAssignmentBatch', 'Apex Class', 'leadsToFuzzyMatch.size(): ' + leadsToFuzzyMatch.size());
            
            LeadFuzzyMatchingBatch.run(this.getIdsFromList(this.leadsToFuzzyMatch), leadIdstoForceAssignmentRules);
            
        } else
            if (!leadIdstoForceAssignmentRules.isEmpty()) {
            //&& (FeatureManagement.checkPermission(FORCE_ASSIGNMENT_RULES_PERMISSION) || LeadMatchingWorker.forceAssignmentRules)) {
                LogWorker.createLogRecord(Datetime.now().millisecond(), '', 'Lead', '', 'LeadMatchingWorker.launchAssignmentBatch', 'Apex Class', 'leadIdstoForceAssignmentRules.size(): ' + leadIdstoForceAssignmentRules.size());
            
            	System.enqueueJob(new LeadForceAssignmentRulesQueueable(leadIdstoForceAssignmentRules));
        	}
    }
	//#endregion
    //#endregion
    
    //#region OTHER
    /**
     * @description Clean instance data
     */
    public void cleanUp() {
        this.accountByNameOrId.clear();
        this.leadsToFuzzyMatch.clear();
    }
}