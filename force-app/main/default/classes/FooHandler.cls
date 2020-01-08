public with sharing class FooHandler extends TriggerHandler{
    public static final String FOO_STATUS_DRAFT = 'Draft';
    public static final String FOO_STATUS_TRANSFORMED = 'Transformed';
    public static final String FOO_STATUS_REVIEW = 'Error';

    private Map<Id, Foo__c> oldFooMap;
    private Map<Id, Foo__c> newFooMap;

    public FooHandler() {
        this.oldFooMap = (Map<Id, Foo__C>) Trigger.oldMap;
        this.newFooMap = (Map<Id, Foo__c>) Trigger.newMap;
    }

    public override void afterUpdate() {
        FooHandler.transformSubmitted(oldFooMap, newFooMap);
    }

    public static void transformSubmitted(Map<Id, Foo__c> oldFoos, Map<Id, Foo__c> newFoos){
        Set<Id> toProcessIds = new Set<Id>();

        for(Foo__c foo : newFoos.values()){
            Foo__c oldFoo = oldFoos.get(foo.Id);
            if(oldFoo.Status__c != foo.Status__c && foo.Status__c == FOO_STATUS_TRANSFORMED ){
                toProcessIds.add(foo.Id);
            }
        }
        if(toProcessIds.isEmpty()) return;


        List<Foo__c> foos = new List<Foo__c>();
        for(Foo__c foo : [SELECT Id FROM Foo__c WHERE Id IN :toProcessIds]){
            foos.add(newFoos.get(foo.Id));
        }

        if(!foos.isEmpty()){
            TransformationUtil.transform('Test_with_Foo', foos);
        }
    }
}   
