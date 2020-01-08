/* global Papa */
import { LightningElement, track } from 'lwc';
import startImportUpsert from '@salesforce/apex/JsonToSObjectImportController.startImportUpsert';
import { loadScript } from 'lightning/platformResourceLoader';
import getPapa from '@salesforce/resourceUrl/Papaparse';

export default class SkillSelectImport extends LightningElement {
    @track loading;
    @track dmlResult;
    @track dmlFailedReason;
    @track sObjectName;
    @track externalId;
    @track errorMessage;

    @track recordLoaded = 0;
    @track objsString;
    @track headers = [];
    @track mapOfListValues = [];

    connectedCallback(){
    }

    papaInitialized = false;
    renderedCallback() {
        if (this.papaInitialized) {
            return;
        }
        this.papaInitialized = true;

        Promise.all([
            loadScript(this, getPapa),
        ])
            .then(() => {
                console.log('Papaparse loaded');
            })
            .catch(error => {
                console.error(error.message);
            });
    }

    handleSObjectName(event){
        this.sObjectName = event.detail.value;
    }

    handleExternalId(event){
        this.externalId = event.detail.value;
    }

    handleTextAreaInput(event) {
        let textAreaInput = this.template.querySelector('.textAreaInput');
        textAreaInput.value = null;
        this.mapOfListValues = [];

        if(event.detail.value) {
            let tabString = event.detail.value;

            Papa.parsePromise = function(a) { // first time parsing, returning a JSON String to pass to Apex
                return new Promise(function(complete, error) {
                    Papa.parse(a, {header:true, complete, error});
                });
            };
            Papa.parsePromise(
                tabString
            ).then(results =>  {
                let resultData = results.data;
                this.objsString = JSON.stringify(resultData);
            });

            // 2nd parse: for displaying the preview table
            Papa.parsePromise = function(b) {
                return new Promise(function(complete, error) {
                    Papa.parse(b, {complete, error});
                });
            };
            Papa.parsePromise(
                tabString
            ).then(results =>  {
                let resultData = [];
                resultData = results.data.slice(1);
                for(let key in resultData) {
                    if (resultData.hasOwnProperty(key)) {
                        this.mapOfListValues.push({key: key, value: resultData[key]});
                    }
                }
                this.headers = results.data[0];
                this.recordLoaded = this.mapOfListValues.length - 1;
                this.dmlResult = null;
                this.loading = false;
            });
        }
    }

    handleImport() {
        console.log(this.sObjectName);
        console.log(this.externalId);
        console.log(this.objsString);

        if (this.sObjectName && this.objsString) {
            this.loading = true;
            startImportUpsert({
                sObjectName: this.sObjectName,
                jsonString: this.objsString,
                externalId: this.externalId,
            }).then(result => {
                this.loading = false;
                this.dmlResult = result.dmlResult;
                this.dmlFailedReason = result.dmlResult === 'Error'? result.dmlFailedReason : null;
                this.objsString = null;
                this.mapOfListValues = [];
                this.headers = [];
            }).catch(error => {
                this.loading = false;
                console.error(error.message);
            });
        } else {
            this.errorMessage = "SObject API Name and data cannot be blank";
        }
    }

}