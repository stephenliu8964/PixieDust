public with sharing class FooHandler extends TriggerHandler{
    private Map<Id, Foo__c> oldFooMap;
    private Map<Id, Foo__c> newFooMap;

    public FooHandler() {
        this.oldFooMap = (Map<Id, Foo__C>) Trigger.oldMap;
        this.newFooMap = (Map<Id, Foo__c>) Trigger.newMap;
    }

    public override void afterUpdate() {
        System.debug('trigger executing');
        //NominationFormResponseUtil.transformSubmitted(oldFooMap, newFooMap);
    }
}   
