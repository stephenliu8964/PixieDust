public without sharing class TransformationUtil {
    public static final String DML_RESULT_PROCESSED = 'Processed';
    public static final String DML_RESULT_ERROR = 'Error';

    private static final String TEXT_TYPE = 'Text';
    private static final String NUMBER_TYPE = 'Number';
    private static final String DATE_TYPE = 'Date';
    private static final String DATETIME_TYPE = 'Datetime';
    private static final String CHECKBOX_TYPE = 'Checkbox';
    private static final String PICKLIST_TYPE = 'Picklist';
    private static final String MULTIPICKLIST_TYPE = 'Multipicklist';
    private static final String LOOKUP_TYPE = 'Lookup';

    private static Transformation_Set__mdt Transformation_Set;
    private static Map<Id, Transformation_Record__mdt> Transformation_Records;
    private static Map<Id, TransformationRecord> Cast_Transformation_Records; //cast with the recordId

    private static List<Transformation_Relationship__mdt> Transformation_Lookups;
    private static Map<Id, List<Transformation_Rule__mdt>> Transformation_Rules;

    private static List<String> recordOrder;
    private static Map<String, Transformed> transformedRecords;
    private static Map<String, Set<String>> dependencies;
    private static Map<Id, String> lockRecords;

    private static String transformationSet;
    private static List<SObject> fromRecords; //assuming no query is required when this is called
    private static List<SObject> toRecords;

    private static Map<String, String> jsonToSObjectFieldMappings; // JSON attribute as key, SObject field as value

    //Objects which datacloud doesn't support
    private static final Set<String> DUPLICATES_NOT_SUPPORTED = new Set<String>{
            'Opportunity'
    };

    //the transform methods are the only methods exposed
    public static void transform(String transformationSet, List<SObject> fromRecords) {

        TransformationUtil.transformationSet = transformationSet;
        TransformationUtil.fromRecords = fromRecords;
        TransformationUtil.toRecords = new List<SObject>();

        /*
           This can't be bulkified well as there's many DML transactions required to support the many records created
           and lookup relationships for each 'from' record. As such, if there's many records passed, we run them one by
           one in @future method.
        */
        if (fromRecords.size() > 1) {
            for (SObject record : fromRecords) {
                TransformationUtil.createRecordsLaterFor(TransformationUtil.transformationSet, record.Id);
            }

        } else {
            //try {
                TransformationUtil.setupData();
                TransformationUtil.createData();
                TransformationUtil.createLookups();
                TransformationUtil.createRecords();
            // } catch (Exception e) {
            //     //TODO need log util to capture error
            //     //TransformationUtil.fail('TransformationUtil.transform', e);
            //     System.debug(e);
            // }

        }
    }

    public static void transform(String transformationSet, Id recordId) {
        String fields;
        TransformationUtil.initTransformation();
        Set<String> fieldSet = new Set<String>();
        for (List<Transformation_Rule__mdt> tRules : Transformation_Rules.values()) {
            for (Transformation_Rule__mdt tRule : tRules) {
                if(!String.isBlank(tRule.From_Field__c)){
                    if(tRule.From_Field__c.contains('.')){
                        fieldSet.add(tRule.From_Field__c.split('\\.')[0].toLowerCase());
                    }
                    else fieldSet.add(tRule.From_Field__c.toLowerCase());
                }
            }
        }

        for(Transformation_Record__mdt tRecord : Transformation_Records.values()){
            if(!String.isBlank(tRecord.conditional__c)){
                List<String> conditionalList = tRecord.conditional__c.split('=');
                fieldSet.add(conditionalList[0].toLowerCase());
            }
        }
        fields = String.join(new List<String>(fieldSet), ', ');
        List<SObject> sobjs =
                Database.query('Select ' + fields + ' from ' + Transformation_Set.From_SObject__c + ' where Id = :recordId');
        TransformationUtil.transform(transformationSet, sobjs);
    }

    public static JsonToSObjectTransformationResult transformJsonToSObject(String sObjectName,String jsonString) {
        return TransformationUtil.transformJsonToSObject(sObjectName, jsonString, null);
    }
    /**
     * @author Stephen Liu
     * @description a public method that does not contain any logic other than a try/catch block to call createRecords(sObjectName, jsonString, externalId)
     * @param sObjectName the name of the SObject that needs to be upserted
     * @param jsonString the JSON string of containing Objects
     * @param externalId if external parameter id received, then upsert base on the external Id
     *
     * @return an instance of the wrapper class indicating DML results
     */
    public static JsonToSObjectTransformationResult transformJsonToSObject(String sObjectName,String jsonString, String externalId) {
        JsonToSObjectTransformationResult ret = new JsonToSObjectTransformationResult();
        try{
            TransformationUtil.initJsonToSObjectTransformation(sObjectName);
            List<SObject> sObjectsToUpsert = TransformationUtil.createRecords(sObjectName, jsonString, jsonToSObjectFieldMappings);
            if (sObjectsToUpsert != null) {
                List<Database.UpsertResult> results = externalId == null ?
                        Database.upsert(sObjectsToUpsert)
                        : Database.upsert(sObjectsToUpsert,Schema.getGlobalDescribe().get(sObjectName).getDescribe().fields.getMap().get(externalId));
            }
            ret.dmlResult = DML_RESULT_PROCESSED;
        } catch (Exception ex) {
            //TODO need a log util to log errors
            //TransformationUtil.fail('JSON to SObject transformation failed', ex);
            ret.dmlResult = DML_RESULT_ERROR;
            ret.dmlFailedReason = ex.getMessage();
        }
        return ret;
    }

    //create records should only be called on one record, this creates all the records in memory.
    private static void createRecords() {
        if (transformedRecords.size() == 1) {
            TransformationUtil.createRecordsFor(transformedRecords.values().get(0));
        } else {
            throw new TransformationException('TransformationUtil.createRecords more than 1 record passed');
        }
    }

    /**
     * @author Stephen Liu
     * @description upsert SObject records with a JSON string using Custom metadata as fields mappings
     * @param sObjectName the name of the SObject that needs to be upserted
     * @param jsonString the JSON string of containing Objects
     * @param externalId if external parameter id received, then upsert base on the external Id
     *
     * @return a list of constructed SObject records, or null if no records have been constructed
     */
    public static List<SObject> createRecords(String sObjectName,String jsonString, Map<String, String> jsonToSObjectFieldMappings) {
        List<Map<String, String>> fieldMaps = (List<Map<String, String>>) JSON.deserialize(jsonString, List<Map<String, String>>.class);
        Schema.SObjectType targetType = Schema.getGlobalDescribe().get(sObjectName);
        Map<String, Schema.SObjectField> targetFields = targetType.getDescribe().fields.getMap();

        List<SObject> sObjectToUpsert;
        sObjectToUpsert = (List<SObject>)Type.forName('List<' + sObjectName  + '>').newInstance();

        for (Map<String, String> fieldMap : fieldMaps) {
            SObject newSobject = targetType.newSObject();
            SObject compareObj = targetType.newSObject();
            for (String key : fieldMap.keySet()) {
                Object value = fieldMap.get(key);
                String sObjectKey = jsonToSObjectFieldMappings.get(key);
                if (sObjectKey == null) continue;

                Schema.DisplayType valueType = targetFields.get(sObjectKey).getDescribe().getType();
                if (value instanceof String && valueType != Schema.DisplayType.STRING) {
                    String sValue = (String)value;
                    if (valueType == Schema.DisplayType.DATE) {
                        newSobject.put(sObjectKey, Date.valueOf(sValue));
                    } else if(valueType == Schema.DisplayType.DATE) {
                        newSobject.put(sObjectKey, Datetime.valueOfGmt(sValue));
                    } else if (valueType == Schema.DisplayType.PERCENT || valueType == Schema.DisplayType.CURRENCY) {
                        newSobject.put(sObjectKey, sValue == '' ? null : Decimal.valueOf(sValue));
                    } else if (valueType == Schema.DisplayType.DOUBLE) {
                        newSobject.put(sObjectKey, sValue == '' ? null : Double.valueOf(sValue));
                    } else if (valueType == Schema.DisplayType.INTEGER) {
                        newSobject.put(sObjectKey, Integer.valueOf(sValue));
                    }else if (valueType == Schema.DisplayType.BASE64) {
                        newSobject.put(sObjectKey, Blob.valueOf(sValue));
                    } else {
                        newSobject.put(sObjectKey, sValue);
                    }
                } else {
                    newSobject.put(sObjectKey, value);
                }
            }
            if (compareObj != newSobject) sObjectToUpsert.add(newSobject);
        }

        return sObjectToUpsert.isEmpty() ? null : sObjectToUpsert;
    }

    //calls transform for each source object in the future
    @Future
    private static void createRecordsLaterFor(String transformationSet, Id recordId) {
        TransformationUtil.transformationSet = transformationSet;
        TransformationUtil.transform(transformationSet, recordId);
    }

    //Creates the records for the given transformed object
    private static void createRecordsFor(Transformed transformed) {
        Map<String, List<SObject>> typeToSObjects = new Map<String, List<SObject>>();
        String sObjectName;
        for (SObject current : transformed.records.values()) {
            sObjectName = current.getSObjectType().getDescribe().name;
            if (!DUPLICATES_NOT_SUPPORTED.contains(sObjectName) && current.Id == null) {
                if (typeToSObjects.get(sObjectName) == null) {
                    typeToSObjects.put(sObjectName, new List<SObject>{
                            current
                    });
                } else {
                    typeToSObjects.get(sObjectName).add(current);
                }
            }
        }
        Savepoint sp = Database.setSavepoint();
        try {
            transformed.doDML();
            transformed.shareFiles();
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }

    }

    //creates lookup relationships for all transformation records passed to this class
    private static void createLookups() {
        for (Transformation_Relationship__mdt lookup : Transformation_Lookups) {
            //get external Id of the To record
            Transformation_Record__mdt toTransRecord = Transformation_Records.get(lookup.To__c);
            Transformation_Record__mdt fromTransRecord = Transformation_Records.get(lookup.From__c);

            String toExtIdFieldName = toTransRecord.External_Id_Field__c;

            for (SObject fromRecord : fromRecords) {
                Transformed transformed = transformedRecords.get(fromRecord.Id);
                SObject fromSobj = transformed.get(fromTransRecord.DeveloperName);
                SObject toSobj = transformed.get(toTransRecord.DeveloperName);
                if (transformed.get(fromTransRecord.DeveloperName + '|0') != null) {
                    for (Integer i = 0;; i++) {

                        fromSobj = transformed.get(fromTransRecord.DeveloperName + '|' + i);
                        if (fromSobj == null) {
                            break;
                        }
                        SObject lookupObject = toSobj.getSObjectType().newSObject();
                        lookupObject.put(toExtIdFieldName, toSobj.get(toExtIdFieldName));
                        String rel = fromSobj.getSObjectType().getDescribe().fields.getMap().get(lookup.Field__c).getDescribe().getRelationshipName();
                        fromSobj.putSObject(rel, lookupObject);
                    }
                }

                if (fromSobj == null || toSobj == null) continue;
                SObject lookupObject = toSobj.getSObjectType().newSObject();
                lookupObject.put(toExtIdFieldName, toSobj.get(toExtIdFieldName));
                String rel = fromSobj.getSObjectType().getDescribe().fields.getMap().get(lookup.Field__c).getDescribe().getRelationshipName();
                fromSobj.putSObject(rel, lookupObject);
            }
        }
    }

    //Sets the external Id for the given transformed record passed, using the Transformation Record External Id Field
    private static void setExternalId(Transformation_Record__mdt tRecord, Transformed transformed) {
        if (!String.isBlank(tRecord.External_Id_Field__c)) {
            Blob b = Crypto.generateAesKey(128);
            String key = EncodingUtil.convertToHex(b);
            SObject sobj = transformed.get(tRecord.DeveloperName);
            if (sobj != null) {
                sobj.put(tRecord.External_Id_Field__c, key);
            } else {
                for (Integer i = 0;; i++) {
                    sobj = transformed.get(tRecord.DeveloperName + '|' + i);
                    if (sobj == null) break;
                    b = Crypto.generateAesKey(128);
                    key = EncodingUtil.convertToHex(b);
                    sobj.put(tRecord.External_Id_Field__c, key);
                }
            }
        }

    }

    private static void JSONTransformation(Transformed transformed, Transformation_Rule__mdt tRule, SObject fromRecord, Id recordId,
            Transformation_Record__mdt tRecord) {
        List<String> sourceFields = tRule.From_Field__c.split('\\.');
        if (sourceFields.size() != 2) {
            throw new TransformationException('Transformation \'From Field\' must not contain more than'
                    + ' one dot (\'.\') character');
        }
        String srcField = sourceFields[0];
        String srcJSONField = sourceFields[1];
        String JSONData = (String) fromRecord.get(srcField);
        if (String.isBlank(JSONData)) {
            //transformed.records.remove(Transformation_Records.get(recordId).DeveloperName);
            return;
        }

        if (JSONData.startsWith('[')) { //handling an array of json objects
            List<Map<String, String>> JSONMap = (List<Map<String, String>>) JSON.deserialize(JSONData, List<Map<String, String>>.class);
            Integer counter = 0;
            //generic version may have had other rules applied - we want these to apply to all repeating quals
            Sobject copy = transformed.records.get(Transformation_Records.get(recordId).DeveloperName);
            for (Map<String, String> currentObject : JSONMap) {
                TransformationRecord castRecord = Cast_Transformation_Records.get(recordId);
                String key = Transformation_Records.get(recordId).DeveloperName + '|' + counter;

                //transformed.put(key, )
                SObject sobj;
                if (transformed.records.get(key) == null) {
                    sobj = copy.clone();
                    //if creating new record - let's also set the external Id
                    setExternalId(tRecord, transformed);
                    if (!String.isBlank(castRecord.Record_TypeId)) {
                        sobj.put('RecordTypeId', castRecord.Record_TypeId);
                    }
                    transformed.records.put(key, sobj);
                } else {
                    sobj = transformed.records.get(key);
                }
                applyRule(tRule, sobj, (String) currentObject.get(srcJSONField));
                counter++;
            }
            //as this is JSON Map and we have many records to the one developer name, we will remove the generic name
            transformed.records.remove(Transformation_Records.get(recordId).DeveloperName);
        } else { //handling a single object in JSON

            TransformationRecord castRecord = Cast_Transformation_Records.get(recordId);
            Map<String, Object> currentObject = (Map<String, Object>) JSON.deserializeUntyped(JSONData);

            SObject sobj;
            if (transformed.records.get(castRecord.DeveloperName) == null) {
                sobj = Schema.getGlobalDescribe().get(castRecord.SObjectType).newSObject();
                //if creating new record - let's also set the external Id
                setExternalId(tRecord, transformed);
                if (!String.isBlank(castRecord.Record_TypeId)) {
                    sobj.put('RecordTypeId', castRecord.Record_TypeId);
                }
                transformed.records.put(castRecord.DeveloperName, sobj);
            } else {
                sobj = transformed.records.get(castRecord.DeveloperName);
            }
            applyRule(tRule, sobj, (String) currentObject.get(srcJSONField));
        }
    }

    private static void standardTransformation(Transformed transformed, Transformation_Rule__mdt tRule, SObject fromRecord, Id recordId,
            Transformation_Record__mdt tRecord) {
        SObject sobj = transformed.get(tRecord.DeveloperName);
        if (sobj != null) {
            if (tRule.From_Field__c != null) {
                applyRule(tRule, sobj, String.valueOf(fromRecord.get(tRule.From_Field__c)));
            } else if (tRule.Value__c != null) {
                applyRule(tRule, sobj, String.valueOf(tRule.Value__c));
            }
        } else {
            for (Integer i = 0;; i++) {
                sobj = transformed.get(tRecord.DeveloperName + '|' + i);
                if (sobj == null) break;
                if (tRule.From_Field__c != null) {
                    applyRule(tRule, sobj, String.valueOf(fromRecord.get(tRule.From_Field__c)));
                } else if (tRule.Value__c != null) {
                    applyRule(tRule, sobj, String.valueOf(tRule.Value__c));
                }
            }
        }
    }

    private static void JSONSObjectTransformation(Transformed transformed, Transformation_Rule__mdt tRule, SObject fromRecord, Id recordId,
            Transformation_Record__mdt tRecord) {
        TransformationRecord castRecord = Cast_Transformation_Records.get(recordId);
        String JSONData = (String) fromRecord.get(tRule.From_Field__c);
        if (String.isBlank(JSONData)) return;
        SObject newSobj = (SObject) JSON.deserialize(JSONData, SObject.class);
        SObject sobj;
        if (transformed.records.get(castRecord.DeveloperName) == null) {
            sobj = Schema.getGlobalDescribe().get(castRecord.SObjectType).newSObject();
            setExternalId(tRecord, transformed);
            if (!String.isBlank(castRecord.Record_TypeId)) {
                sobj.put('RecordTypeId', castRecord.Record_TypeId);
            }
            transformed.records.put(castRecord.DeveloperName, sobj);
        } else {
            sobj = transformed.records.get(castRecord.DeveloperName);
        }
        for (String field : newSobj.getPopulatedFieldsAsMap().keySet()) {
            sobj.put(field, newSobj.get(field));
        }
    }

    //this can be optimised to be run first against all records, then stored statically
    private static Boolean transformationAllowed(Transformed transformed, SObject fromRecord, Transformation_Record__mdt tRecord) {
        String conditional = tRecord.conditional__c;
        if (!String.isBlank(conditional)) {
            //this transformation record should only be created if certain condition is met.
            List<String> conditionalList = conditional.split('=');
            if (conditionalList.size() != 2) {
                throw new TransformationException('Conditional rule on Transformation Record '
                        + tRecord.DeveloperName + ' is not configured ' +
                        'correctly');
            }
            String fieldToCheck = conditionalList.get(0);
            String valueToCheck = conditionalList.get(1);
            Boolean isBooleanAndTrue = false;
            try {
                isBooleanAndTrue = (Boolean) fromRecord.get(fieldToCheck) && valueToCheck == 'true';
            } catch (Exception e) {
                //we don't do anything here, if fails it should remain as false (as per declaration)
            }

            if (fromRecord.get(fieldToCheck) != valueToCheck || isBooleanAndTrue) {
                //if condition not met we aren't creating this record - so remove it!
                transformed.records.remove(tRecord.DeveloperName);
                return false;
            }
        }
        return true;
    }
    //Creates the data for the various records to be created (i.e. fills the fields with appropriate values)
    private static void createData() {
        transformedRecords = new Map<String, Transformed>();

        for (SObject fromRecord : fromRecords) {
            transformedRecords.put(fromRecord.Id, new Transformed(fromRecord.Id));
        }

        for (SObject fromRecord : fromRecords) {
            //set all the external Ids first
            for (Transformation_Record__mdt tRecord : Transformation_Records.values()) {
                setExternalId(tRecord, transformedRecords.get(fromRecord.Id));
            }
            Transformed transformed = transformedRecords.get(fromRecord.Id);

            for (Id recordId : Transformation_Rules.keySet()) {

                Transformation_Record__mdt tRecord = Transformation_Records.get(recordId);
                //for each rule under each transformation record, for each from record (source record to be transformed)
                for (Transformation_Rule__mdt tRule : Transformation_Rules.get(recordId)) {
                    //tRecord may get removed within this loop, so check. Then fetch the transformed obj
                    if (tRecord == null) continue;


                    //check conditional 'only create when' rule on the trans record
                    if (transformationAllowed(transformed, fromRecord, tRecord)) {
                        //at this point in the loop we know we are performing the transformation, but there are a few types
                        if (tRule.From_Field__c != null && tRule.From_Field__c.contains('.') && !tRule.Map_to_Record__c) {
                            JSONTransformation(transformed, tRule, fromRecord, recordId, tRecord);
                        } else if (!tRule.Map_to_Record__c) {
                            standardTransformation(transformed, tRule, fromRecord, recordId, tRecord);
                        } else {
                            JSONSObjectTransformation(transformed, tRule, fromRecord, recordId, tRecord);
                        }
                    }
                }
            }
        }

    }

    private static String translate(String data, String translations) {
        if (String.isBlank(translations)) return data;
        List<String> translationParts;
        String translateFrom;
        String translateTo;
        for (String translation : translations.split('\\|')) {
            translationParts = translation.split('=');
            if (translationParts.isEmpty()) continue;
            if (translationParts.size() != 2) {
                throw new TransformationException('Translation does not look correct, found: "' + translation + '" for one rule, data: ' + data);
            }
            translateFrom = translationParts.get(0);
            translateTo = translationParts.get(1);
            if (data == translateFrom) {
                return translateTo;
            }
        }
        return data;
    }

    private static void applyRule(Transformation_Rule__mdt rule, SObject targetObject, String data) {
        try {
            data = translate(data, rule.Translation__c);
        } catch (TransformationException te) {
            throw new TransformationException(te.getMessage() + ', on Rule: ' + rule.DeveloperName);
        }

        try {
            if (String.isBlank(data)) return; //if no value, don't apply rule.
            if (rule.Field_Type__c == TEXT_TYPE || rule.Field_Type__c == PICKLIST_TYPE || rule.Field_Type__c == LOOKUP_TYPE) {
                targetObject.put(rule.To_Field__c, data);
            } else if (rule.Field_Type__c == DATE_TYPE) {
                Date targetDataDate;
                try {
                    targetDataDate = Date.valueOf(data);
                } catch (Exception e) {
                    // we try parsing as valueOf (apexFormat) or parse (std format)
                    targetDataDate = Date.parse(data);
                }
                targetObject.put(rule.To_Field__c, targetDataDate);
            } else if (rule.Field_Type__c == DATETIME_TYPE) {
                Datetime targetDataDate;
                try {
                    targetDataDate = Datetime.valueOf(data);
                } catch (Exception e) {
                    // we try parsing as valueOf (apexFormat) or parse (std format)
                    targetDataDate = Datetime.parse(data);
                }
                targetObject.put(rule.To_Field__c, targetDataDate);
            } else if (rule.Field_Type__c == CHECKBOX_TYPE) {
                if (data.toLowerCase() == 'yes' || data.toLowerCase() == 'true') {
                    targetObject.put(rule.To_Field__c, true);
                } else {
                    targetObject.put(rule.To_Field__c, false);
                }
            } else if (rule.Field_Type__c == MULTIPICKLIST_TYPE) {
                if (data.contains('[')) {
                    List<String> options = (List<String>) JSON.deserialize(data,
                            List<String>.class);
                    data = '';
                    for (String option : options) {
                        data += option + ';';
                    }
                    data.removeEnd(';');
                }
                targetObject.put(rule.To_Field__c, data);
            } else if (rule.Field_Type__c == NUMBER_TYPE) {
                //sometimes we might map to the same field in 2 contexts, the non zero should always win. if the toField is set, and the new value is 0, we don't overwrite
                if (rule.To_Field__c != null && Decimal.valueOf(data) == 0) return;
                targetObject.put(rule.To_Field__c, Decimal.valueOf(data));
            }
        } catch (Exception e) {
            e.setMessage(e.getMessage() + ', on rule: ' + rule.DeveloperName);
            throw e;
        }

    }

    private static void wrapTransformationRecords() {
        //firstly we wrap our sobjects to our own TransformationRecord, grouping by the SObject Type
        Map<String, List<TransformationUtil.TransformationRecord>> objectsToRecords =
                new Map<String, List<TransformationUtil.TransformationRecord>>();
        for (Transformation_Record__mdt record : Transformation_Records.values()) {
            TransformationUtil.TransformationRecord tr =
                    new TransformationUtil.TransformationRecord(record);

            if (objectsToRecords.get(tr.SObjectType) == null) {
                objectsToRecords.put(tr.SObjectType, new List<TransformationUtil.TransformationRecord>{
                        tr
                });
            } else {
                objectsToRecords.get(tr.SObjectType).add(tr);
            }
        }

        //Now we set the RecordType Id for each TransformationRecord, based on the given Record Type name
        for (Schema.DescribeSObjectResult describe :
                Schema.describeSObjects(new List<String>(objectsToRecords.keySet()))) {
            for (TransformationUtil.TransformationRecord tr : objectsToRecords.get(describe.getName())) {
                if (!String.isBlank(tr.Record_Type)) {
                    tr.Record_TypeId = describe.getRecordTypeInfosByName().get(tr.Record_Type).getRecordTypeId();
                }
            }
        }

        //We want to easily discover each transformation with it's recordTypeId, so return a map
        Cast_Transformation_Records = new Map<Id, TransformationRecord>();
        for (List<TransformationUtil.TransformationRecord> trl : objectsToRecords.values()) {
            for (TransformationUtil.TransformationRecord tr : trl) {
                Cast_Transformation_Records.put(tr.Id, tr);
            }
        }

    }

    private static void lockRecords(){
        if(fromRecords != null && fromRecords.size() == 1 && Transformation_Set.Lock_Record_s__c != null){
            List<String> lockReferences = Transformation_Set.Lock_Record_s__c.split(',');

            for(String lockReference : lockReferences){
                if(String.isBlank(lockReference)) continue;

                List<String> lockRefSplit = lockReference.split(':');
                if(lockRefSplit.size() != 2) continue;
                String sobjectName = lockRefSplit.get(1);
                String field = lockRefSplit.get(0);
                String theId = (String) fromRecords.get(0).get(field);
                
                //lock the record for each lock reference
                if(!String.isBlank(theId) && !String.isBlank(field)){
                    Database.query('SELECT Id FROM ' + sobjectName + ' WHERE Id = \'' + theId + '\' FOR UPDATE');
                }
            }
        }
    }

    private static void initTransformation() {

        if(TransformationUtil.Transformation_Set == null){
        List<Transformation_Set__mdt> sets = [
                SELECT Id, From_SObject__c, On_Error_Field__c, On_Error_Value__c,
                            DeveloperName, Lock_Record_s__c
                FROM Transformation_Set__mdt
                WHERE DeveloperName = :transformationSet
        ];

        if (sets.isEmpty()) {
            return;
        }
        TransformationUtil.Transformation_Set = sets.get(0);

            TransformationUtil.lockRecords();
        }

        Transformation_Records = new Map<Id, Transformation_Record__mdt>([
                SELECT Id, DeveloperName, SObject__c,
                        External_Id_Field__c, Record_Type__c, Transformation_Set__c, conditional__c, Share_Files__c
                FROM
                        Transformation_Record__mdt
                WHERE Transformation_Set__c = :Transformation_Set.Id
        ]);

        //now we can cast the transformation records to our own type bound with the record type Id
        TransformationUtil.wrapTransformationRecords();

        //Transformation rules we want to group by their respective records
        Transformation_Rules = new Map<Id, List<Transformation_Rule__mdt>>();
        List<Transformation_Rule__mdt> tempRule = [
                SELECT Id, DeveloperName, Field_Type__c,
                        From_Field__c, To_Field__c, Transformation_Record__c, Translation__c, Value__c, Map_to_Record__c
                FROM
                        Transformation_Rule__mdt
                WHERE Transformation_Record__c IN :Transformation_Records.keySet()
        ];
        TransformationUtil.lockRecords = new Map<Id, String>();
        for (Transformation_Rule__mdt tRule : tempRule) {
            if (Transformation_Rules.get(tRule.Transformation_Record__c) == null) {
                Transformation_Rules.put(tRule.Transformation_Record__c, new List<Transformation_Rule__mdt>{
                        tRule
                });
            } else {
                Transformation_Rules.get(tRule.Transformation_Record__c).add(tRule);
            }
        }

        //Transformation lookups
        Transformation_Lookups = [
                SELECT Id,
                        DeveloperName, From__c, To__c, Field__c
                FROM Transformation_Relationship__mdt
                WHERE From__c
                        IN :Transformation_Records.keySet()
        ];

    }

    private static void initJsonToSObjectTransformation(String sObjectName) {
        List<Import_Field_Mapping__mdt> mappings = [SELECT From_JSON_Attribute__c, To_SObject_Field__c FROM Import_Field_Mapping__mdt WHERE JSON_Import_to_SObject__r.SObject_API_Name__c = :sObjectName];
        if (mappings.isEmpty()) return;

        jsonToSObjectFieldMappings = new Map<String,String>();
        for (Import_Field_Mapping__mdt mapping : mappings) { // Reason for not using SOQl for loop is: there is a Salesforce bug that use SOQL For Loop with Custom Metadata will not full retrieve all records
            jsonToSObjectFieldMappings.put(mapping.From_JSON_Attribute__c, mapping.To_SObject_Field__c);
        }
    }

    private static void setupData() {
        if (Transformation_Records == null || Transformation_Records.isEmpty()) {
            TransformationUtil.initTransformation();
        } else {
            TransformationUtil.lockRecords();
        }
        if (Transformation_Records == null || Transformation_Records.isEmpty()) return;


        //here we're simply setting up the order that the record types must be inserted.
        dependencies = new Map<String, Set<String>>();
        for (Transformation_Relationship__mdt lookup : Transformation_Lookups) {
            if (dependencies.get(lookup.From__c) == null) {
                dependencies.put(lookup.From__c, new Set<String>{
                        lookup.To__c
                });
            } else {
                dependencies.get(lookup.From__c).add(lookup.To__c);
            }
        }

        Map<String, Set<String>> recordToAllDependencies = new Map<String, Set<String>>();
        for (Transformation_Record__mdt tRecord : Transformation_Records.values()) {
            recordToAllDependencies.put(tRecord.Id, getDependencies(tRecord));
        }
        recordOrder = orderedDependencies(recordToAllDependencies);
    }

    //these are recursive functions used to order our dependent trans records - not intended for use outside this class
    private static List<String> orderedDependencies(Map<String, Set<String>> allDeps) {
        List<String> done = new List<String>();
        return orderedDependencies(allDeps, done);
    }
    private static List<String> orderedDependencies(Map<String, Set<String>> allDeps, List<String> done) {
        return orderedDependencies(allDeps, done, null);
    }
    private static List<String> orderedDependencies(Map<String, Set<String>> allDeps, List<String> done, Id parent) {
        for (String dep : allDeps.keySet()) {
            if (allDeps.get(dep).isEmpty()) {
                allDeps.remove(dep);
                done.add(dep);
            } else if (allDeps.get(dep).size() == 1) {
                for (String child : allDeps.get(dep)) {
                    if (allDeps.get(child) != null && allDeps.get(child).contains(dep)) {
                        allDeps.remove(dep);
                        done.add(dep);
                    }
                }
            }

            if (allDeps.get(dep) != null && !allDeps.get(dep).isEmpty()) {
                for (String childDep : allDeps.get(dep)) {
                    for (String doneItem : done) {
                        if (doneItem == childDep) {
                            allDeps.get(dep).remove(childDep);
                        }
                    }
                }
            }
        }
        if (!allDeps.isEmpty()) {
            orderedDependencies(allDeps, done, parent);
        }
        return done;
    }
    private static Set<String> getDependencies(Transformation_Record__mdt tRecord) {
        if (dependencies == null || dependencies.get(tRecord.Id) == null) {
            return new Set<String>{
            };
        } else {
            Set<String> theList = new Set<String>();
            Transformation_Record__mdt otherRecord;
            for (String dependency : dependencies.get(tRecord.Id)) {
                otherRecord = Transformation_Records.get(dependency);
                theList.add(otherRecord.Id);
                theList.addAll(getDependencies(otherRecord));
            }
            return theList;
        }
    }

    //deduplication here is comprehensive enough for the purpose of transformations - but not suitable for other classes
    private static void dedupe(SObject sobj) {
        TransformationUtil.dedupe(new List<SObject>{
                sobj
        });
    }
    private static void dedupe(List<SObject> sobjs) {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.duplicateRuleHeader.allowSave = true;
        dml.optAllOrNone = false;
        dml.allowFieldTruncation = true;
        List<Database.SaveResult> saveResults = Database.insert(sobjs, dml);
        Database.SaveResult saveResult;
        SObject sobj;
        List<SObject> updates = new List<SObject>();

        for (Integer i = 0; i < saveResults.size(); i++) {
            saveResult = saveResults.get(i);
            sobj = sobjs.get(i);
            if (!saveResult.isSuccess()) {
                for (Database.Error error : saveResult.getErrors()) {
                    if (error instanceof Database.DuplicateError) {
                        Database.DuplicateError duplicateError = (Database.DuplicateError) error;
                        Datacloud.DuplicateResult duplicateResult = duplicateError.getDuplicateResult();
                        if (!duplicateResult.isAllowSave()) {
                            Datacloud.MatchRecord[] matchRecords = duplicateResult.getMatchResults()[0].getMatchRecords();
                            //todo - for any object we're updating, we need to remove any fields from rules which don't
                            //   have 'overwrite'
                            sobj.put('Id', matchRecords.get(0).getRecord().get('Id'));
                            updates.add(sobj);
                        }

                    } else {
                        throw new TransformationException('TransformationUtil.dedupe - non duplicate DML error: ' + sobj + error);
                    }
                }
            }

        }

        if (!updates.isEmpty()) Database.update(updates);
    }

    //todo - change who get's emailed based on the Transformation Set (i.e. 'email errors to' field)
    private static void fail(String src, Exception e) {
        TransformationUtil.fail(src, e, null);
    }

    private static void fail(Transformation_Rule__mdt tRule, Exception e) {
        String src = 'Problematic rule: ' + tRule;
        fail(src, e);
    }

    private static void fail(String src, Exception e, Id nfrId) {
        String errorMsg = '';
        if (nfrId != null) {
            errorMsg += 'An error occured on NFR record: ' + nfrId + '\n';
        }
        errorMsg += 'Error details: ' + '\n\nSource: ' + src + '\n\nCause: ' + e.getCause() + '\n\nException: ' + e.getMessage() + '\n\n Trace: ' + e.getStackTraceString();
        if (Transformation_Set == null) return;
        if (!fromRecords.isEmpty()) {
            SObject fromRecord = fromRecords.get(0);
            SObject currentSobj = Schema.getGlobalDescribe().get(Transformation_Set.From_SObject__c).newSObject();
            currentSobj.put('Id', fromRecord.Id);
            currentSobj.put(Transformation_Set.On_Error_Field__c, Transformation_Set.On_Error_Value__c);
            //currentSobj.put('Transformation_Error_Details__c', errorMsg);
            update currentSobj;
        }
    }

    //we wrap our Transformation_Record__mdt records here to store the Record_TypeId
    private class TransformationRecord {
        public Id Id;
        public String DeveloperName;
        public String SObjectType;
        public String Record_Type;
        public Id Record_TypeId;
        public Id Transformation_Set;
        public String External_Id_Field;

        public TransformationRecord(Transformation_Record__mdt tr) {
            this.Id = tr.Id;
            this.DeveloperName = tr.DeveloperName;
            this.SObjectType = tr.SObject__c;
            this.Record_Type = tr.Record_Type__c;
            this.Transformation_Set = tr.Transformation_Set__c;
            this.External_Id_Field = tr.External_Id_Field__c;
        }
    }

    //Transformed is a wrapper holding the source (from) record Id, as well as all the records which need to be generated
    private class Transformed {
        public Id sourceRecordId;
        public Map<String, SObject> records { get; set; }

        public Transformed(Id sourceRecordId) {
            this.sourceRecordId = sourceRecordId;
            this.makeRecords();
        }

        private void makeRecords() {
            this.records = new Map<String, SObject>();
            //first let's figure out which fields to create
            for (TransformationRecord tr : TransformationUtil.Cast_Transformation_Records.values()) {
                SObject newRecord = Schema.getGlobalDescribe().get(tr.SObjectType).newSObject();
                if (!String.isBlank(tr.Record_TypeId)) {
                    newRecord.put('RecordTypeId', tr.Record_TypeId);
                }
                records.put(tr.DeveloperName, newRecord);
            }
        }

        public SObject get(String SObjectName) {
            return this.records.get(SObjectName);
        }

        public void doDML() {
            List<SObject> updates = new List<SObject>();
            List<SObject> inserts = new List<SObject>();
            for (String tRecordId : recordOrder) {
                String recordKey = Transformation_Records.get(tRecordId).DeveloperName;
                SObject sobj = this.records.get(recordKey);
                if (sobj != null && sobj.get('Id') != null) {
                    update sobj;
                } else if (sobj != null) {
                    TransformationUtil.dedupe(sobj);
                } else {
                    updates = new List<SObject>();
                    inserts = new List<SObject>();
                    for (Integer i = 0;; i++) {
                        String jsonKey = recordKey + '|' + i;
                        sobj = this.records.get(jsonKey);
                        if (sobj == null) {
                            break;
                        }
                        if (sobj.get('Id') != null) {
                            updates.add(sobj);
                        } else {
                            inserts.add(sobj);
                        }
                    }
                    TransformationUtil.dedupe(inserts);
                    update updates;
                }
            }
        }

        public void shareFiles() {
            //find files
            Set<Id> fileIds = new Set<Id>();
            List<ContentDocumentLink> cDesTemp = [
                    SELECT Id, ContentDocumentId
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId = :sourceRecordId
            ];

            for (ContentDocumentLink cDe : cDesTemp) {
                fileIds.add(cDe.ContentDocumentId);
            }

            if (fileIds.isEmpty()) return;

            Set<String> shareTo = new Set<String>();
            for (Transformation_Record__mdt tRecord : Transformation_Records.values()) {
                if (tRecord.Share_Files__c) {
                    shareTo.add(tRecord.DeveloperName);
                }
            }

            Set<Id> shareIds = new Set<Id>();
            for (String shareDevName : shareTo) {
                SObject sobj = this.records.get(shareDevName);
                if (sobj == null) {
                    for (Integer i = 0; i < shareTo.size(); i++) {
                        sobj = this.records.get(shareDevName + '|' + i);
                        if (sobj == null) break;
                        shareIds.add((Id) sobj.get('id'));
                    }
                } else {
                    shareIds.add((Id) sobj.get('id'));
                }
            }

            List<ContentDocumentLink> cDes = new List<ContentDocumentLink>();
            for (Id shareId : shareIds) {
                for (Id fileId : fileIds) {
                    ContentDocumentLink cDe = new ContentDocumentLink();
                    cDe.ContentDocumentId = fileId;
                    cDe.LinkedEntityId = shareId;
                    cDe.ShareType = 'I';
                    cDe.Visibility = 'AllUsers';
                    cDes.add(cDe);
                }
            }
            insert cDes;

        }

    }

    public class JsonToSObjectTransformationResult {
        @AuraEnabled public String dmlResult {get; set;}
        @AuraEnabled public String passedJson {get; set;}
        @AuraEnabled public String failedJson {get; set;}
        @AuraEnabled public String dmlFailedReason {get; set;}

        public JsonToSObjectTransformationResult(){}

        public JsonToSObjectTransformationResult(String dmlResult, String passedJson, String failedJson) {
            this.dmlResult = dmlResult;
            this.passedJson = passedJson;
            this.failedJson = failedJson;
            this.dmlFailedReason = dmlFailedReason;
        }
    }

    public class TransformationException extends Exception {
    }
}
