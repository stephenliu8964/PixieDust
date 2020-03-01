#!/bin/sh

PERMSET_NAME=Transformation_Engine_User

while [ ! -n "$ORG_NAME"  ] 
do
	echo "🐱  Please enter a name for your scratch org:"
	read ORG_NAME
done

echo "🐱  Building your org, please wait."
sfdx force:org:create -f config/project-scratch-def.json -a ${ORG_NAME} --json

if [ "$?" = "1" ] 
then
	echo "🐱 Can't create your org."
	exit
fi

sfdx force:source:push -u ${ORG_NAME}

if [ "$?" = "1" ]
then 
	echo "🐱  Can't push your source."
	exit 
fi

echo "🐱  Code is pushed successfully."

sfdx force:user:permset:assign -n ${PERMSET_NAME} -u ${ORG_NAME} --json

if [ "$?" = "1" ]
then
	echo "🐱  Can't assign the permission set."
	exit 
fi	

echo "🐱  Permission set is assigned successfully."

sfdx force:org:open -u ${ORG_NAME}