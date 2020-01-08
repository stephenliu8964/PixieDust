public without sharing class JsonToSObjectImportController {

    @AuraEnabled
    public static TransformationUtil.JsonToSObjectTransformationResult startImportUpsert(String sObjectName, String jsonString, String externalId){
        return TransformationUtil.transformJsonToSObject(sObjectName, jsonString, externalId);
    }
}
