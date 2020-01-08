public without sharing class JsonToSObjectImportController {
    public JsonToSObjectImportController() {

    }

    @AuraEnabled
    public static string startImportUpsert(String sObjectName, String jsonString, String externalId){
        System.debug(sObjectName);
        System.debug(jsonString);
        System.debug(externalId);
        return null;
    }
}
